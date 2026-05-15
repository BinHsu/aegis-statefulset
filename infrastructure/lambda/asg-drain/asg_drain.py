# asg_drain.py
#
# Node-drain Lambda for the stateful node groups (ADR-04).
#
# Trigger: SNS, fed by an Auto Scaling Group TERMINATING lifecycle hook
# (see infrastructure/terraform/lifecycle-hooks.tf). When a stateful node
# is about to terminate, the ASG pauses and notifies this Lambda, which:
#
#   1. Resolves the EC2 instance to its Kubernetes node name.
#   2. Cordons the node (spec.unschedulable = true) so no new pods land.
#   3. Evicts every non-DaemonSet, non-mirror pod via the eviction API —
#      this is a graceful drain: K8s sends SIGTERM, the stateful app's
#      signal handler runs http.Server.Shutdown + LevelDB Close + fsync,
#      bounded by terminationGracePeriodSeconds (ADR-02 § Graceful shutdown).
#   4. Calls complete_lifecycle_action so the ASG proceeds with termination.
#
# Design guarantees:
#   - The lifecycle action is ALWAYS completed (CONTINUE) in a finally
#     block, even when the drain fails — a stuck lifecycle hook would
#     freeze the whole ASG for the heartbeat_timeout (10 min) and then
#     ABANDON, which is worse than a best-effort drain.
#   - No third-party pip dependencies: boto3 ships in the Lambda python3.11
#     runtime; everything else is stdlib. The deployment artefact is a
#     single-file zip (built by terraform's archive_file data source).
#
# Prerequisite for full function (NOT wired by this Lambda):
#   The Lambda execution role must be granted Kubernetes RBAC able to
#   patch nodes + create pod evictions — via an aws_eks_access_entry (or
#   aws-auth mapping) bound to a ClusterRole with those verbs. Until that
#   exists the Lambda still completes the lifecycle action (the ASG never
#   hangs) but the cordon/evict calls return 403 and are logged as such.

from __future__ import annotations

import base64
import json
import logging
import os
import ssl
import tempfile
import urllib.request
from typing import Any

import boto3
from botocore.signers import RequestSigner

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

CLUSTER_NAME = os.environ["CLUSTER_NAME"]
REGION = os.environ.get("AWS_REGION", "eu-central-1")

_eks = boto3.client("eks", region_name=REGION)
_ec2 = boto3.client("ec2", region_name=REGION)
_asg = boto3.client("autoscaling", region_name=REGION)


# ---- EKS auth -------------------------------------------------------------

def _eks_bearer_token(cluster_name: str) -> str:
    """Mint a short-lived EKS bearer token (the aws-iam-authenticator
    'k8s-aws-v1.' presigned-STS-URL scheme)."""
    session = boto3.Session()
    sts = session.client("sts", region_name=REGION)
    signer = RequestSigner(
        sts.meta.service_model.service_id,
        REGION,
        "sts",
        "v4",
        session.get_credentials(),
        session.events,
    )
    signed_url = signer.generate_presigned_url(
        {
            "method": "GET",
            "url": (
                f"https://sts.{REGION}.amazonaws.com/"
                "?Action=GetCallerIdentity&Version=2011-06-15"
            ),
            "body": {},
            "headers": {"x-k8s-aws-id": cluster_name},
            "context": {},
        },
        region_name=REGION,
        expires_in=60,
        operation_name="",
    )
    encoded = base64.urlsafe_b64encode(signed_url.encode("utf-8")).decode("utf-8")
    return "k8s-aws-v1." + encoded.rstrip("=")


def _k8s_session() -> tuple[str, str, str]:
    """Return (api_endpoint, bearer_token, ca_cert_path) for the cluster."""
    desc = _eks.describe_cluster(name=CLUSTER_NAME)["cluster"]
    endpoint = desc["endpoint"]
    ca_data = base64.b64decode(desc["certificateAuthority"]["data"])
    ca_file = tempfile.NamedTemporaryFile(
        mode="wb", suffix=".crt", delete=False
    )
    ca_file.write(ca_data)
    ca_file.close()
    return endpoint, _eks_bearer_token(CLUSTER_NAME), ca_file.name


def _k8s_request(
    endpoint: str,
    token: str,
    ca_path: str,
    method: str,
    path: str,
    body: dict[str, Any] | None = None,
    content_type: str = "application/json",
) -> tuple[int, Any]:
    ctx = ssl.create_default_context(cafile=ca_path)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        f"{endpoint}{path}", data=data, method=method
    )
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            payload = resp.read().decode("utf-8")
            return resp.status, json.loads(payload) if payload else {}
    except urllib.error.HTTPError as exc:
        payload = exc.read().decode("utf-8")
        return exc.code, json.loads(payload) if payload else {}


# ---- drain logic ----------------------------------------------------------

def _node_name_for_instance(instance_id: str) -> str | None:
    """K8s node name for an EC2 instance is its private DNS name."""
    reservations = _ec2.describe_instances(InstanceIds=[instance_id])[
        "Reservations"
    ]
    for res in reservations:
        for inst in res["Instances"]:
            dns = inst.get("PrivateDnsName")
            if dns:
                return dns
    return None


def _cordon(endpoint: str, token: str, ca: str, node: str) -> None:
    # K8s PATCH needs an explicit patch content-type; merge-patch is the
    # simplest for a single spec field.
    status, body = _k8s_request(
        endpoint, token, ca, "PATCH",
        f"/api/v1/nodes/{node}",
        {"spec": {"unschedulable": True}},
        content_type="application/merge-patch+json",
    )
    if status >= 400:
        logger.warning("cordon %s -> HTTP %s: %s", node, status, body)
    else:
        logger.info("cordoned node %s", node)


def _evict_pods(endpoint: str, token: str, ca: str, node: str) -> None:
    status, body = _k8s_request(
        endpoint, token, ca, "GET",
        f"/api/v1/pods?fieldSelector=spec.nodeName={node}",
    )
    if status >= 400:
        logger.warning("list pods on %s -> HTTP %s: %s", node, status, body)
        return
    for pod in body.get("items", []):
        meta = pod.get("metadata", {})
        ns, name = meta.get("namespace"), meta.get("name")
        owners = meta.get("ownerReferences", [])
        # Skip DaemonSet pods (re-created on the node regardless) and
        # static/mirror pods (no controller, evicting them is a no-op).
        if any(o.get("kind") == "DaemonSet" for o in owners):
            continue
        if "kubernetes.io/config.mirror" in (meta.get("annotations") or {}):
            continue
        ev_status, ev_body = _k8s_request(
            endpoint, token, ca, "POST",
            f"/api/v1/namespaces/{ns}/pods/{name}/eviction",
            {
                "apiVersion": "policy/v1",
                "kind": "Eviction",
                "metadata": {"name": name, "namespace": ns},
            },
        )
        if ev_status >= 400:
            logger.warning("evict %s/%s -> HTTP %s: %s", ns, name, ev_status, ev_body)
        else:
            logger.info("evicted pod %s/%s", ns, name)


# ---- handler --------------------------------------------------------------

def handler(event: dict[str, Any], _context: Any) -> dict[str, str]:
    """SNS-wrapped ASG lifecycle hook entry point."""
    for record in event.get("Records", []):
        message = json.loads(record["Sns"]["Message"])

        # The ASG also sends a one-off test notification on hook creation;
        # it has no LifecycleTransition and must be ignored.
        if "LifecycleTransition" not in message:
            logger.info("ignoring non-lifecycle message: %s", message.get("Event"))
            continue

        asg_name = message["AutoScalingGroupName"]
        hook_name = message["LifecycleHookName"]
        instance_id = message["EC2InstanceId"]
        token_param = message["LifecycleActionToken"]

        try:
            node = _node_name_for_instance(instance_id)
            if node:
                endpoint, k8s_token, ca = _k8s_session()
                _cordon(endpoint, k8s_token, ca, node)
                _evict_pods(endpoint, k8s_token, ca, node)
            else:
                logger.warning("no node name for instance %s — skipping drain", instance_id)
        except Exception:  # noqa: BLE001 — best-effort; never block the ASG
            logger.exception("drain failed for instance %s", instance_id)
        finally:
            # ALWAYS let the ASG proceed. A drain that errored is better
            # resolved by the pod's own terminationGracePeriod than by
            # freezing the ASG until the hook heartbeat times out.
            _asg.complete_lifecycle_action(
                LifecycleHookName=hook_name,
                AutoScalingGroupName=asg_name,
                LifecycleActionToken=token_param,
                LifecycleActionResult="CONTINUE",
            )
            logger.info("completed lifecycle action for instance %s", instance_id)

    return {"status": "ok"}
