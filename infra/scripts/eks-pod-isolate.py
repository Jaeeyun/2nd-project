
import base64
import json
import os
import ssl
import urllib.error
import urllib.request

import boto3
from botocore.signers import RequestSigner

eks = boto3.client("eks")
sns = boto3.client("sns")

CLUSTER_NAME = os.environ["CLUSTER_NAME"]
REGION = os.environ["AWS_REGION"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

def _get_eks_token(cluster_name: str) -> str:
    session = boto3.session.Session()
    sts = session.client("sts", region_name=REGION)
    service_id = sts.meta.service_model.service_id
    signer = RequestSigner(service_id, REGION, "sts", "v4", session.get_credentials(), session.events)
    params = {
        "method": "GET",
        "url": f"https://sts.{REGION}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
        "body": {},
        "headers": {"x-k8s-aws-id": cluster_name},
        "context": {},
    }
    signed_url = signer.generate_presigned_url(params, region_name=REGION, expires_in=60, operation_name="")
    token = "k8s-aws-v1." + base64.urlsafe_b64encode(signed_url.encode()).decode().rstrip("=")
    return token

def _k8s_request(endpoint: str, ca_data: str, token: str, method: str, path: str, body=None, content_type="application/json"):
    ctx = ssl.create_default_context(cadata=base64.b64decode(ca_data).decode())
    url = f"{endpoint}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, context=ctx) as resp:
        return json.loads(resp.read().decode()) if resp.length != 0 else {}

def _extract_pod_info(event: dict):

    if "namespace" in event and "pod_name" in event:
        return event["namespace"], event["pod_name"]

    try:
        detail = event["detail"]
        finding = detail["findings"][0] if "findings" in detail else detail
        resources = finding.get("Resources", [])
        for r in resources:
            k8s = r.get("Details", {}).get("AwsEksCluster", {})
            if "pod_name" in k8s:
                return k8s.get("namespace", "default"), k8s["pod_name"]
    except (KeyError, IndexError):
        pass

    raise ValueError("파드 이름/네임스페이스를 이벤트에서 추출하지 못했습니다. 수동으로 {'namespace':..,'pod_name':..} 형태로 재호출하세요.")

def handler(event, context):
    namespace, pod_name = _extract_pod_info(event)

    cluster = eks.describe_cluster(name=CLUSTER_NAME)["cluster"]
    endpoint = cluster["endpoint"]
    ca_data = cluster["certificateAuthority"]["data"]
    token = _get_eks_token(CLUSTER_NAME)

    _k8s_request(
        endpoint, ca_data, token, "PATCH",
        f"/api/v1/namespaces/{namespace}/pods/{pod_name}",
        body={"metadata": {"labels": {"quarantine": "true"}}},
        content_type="application/strategic-merge-patch+json",
    )

    netpol_name = "quarantine-deny-all"
    try:
        _k8s_request(endpoint, ca_data, token, "GET",
                     f"/apis/networking.k8s.io/v1/namespaces/{namespace}/networkpolicies/{netpol_name}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            _k8s_request(
                endpoint, ca_data, token, "POST",
                f"/apis/networking.k8s.io/v1/namespaces/{namespace}/networkpolicies",
                body={
                    "apiVersion": "networking.k8s.io/v1",
                    "kind": "NetworkPolicy",
                    "metadata": {"name": netpol_name, "namespace": namespace},
                    "spec": {
                        "podSelector": {"matchLabels": {"quarantine": "true"}},
                        "policyTypes": ["Ingress", "Egress"],
                        "ingress": [],
                        "egress": [],
                    },
                },
            )
        else:
            raise

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="EKS 파드 격리 완료",
        Message=(
            f"🔒 파드 격리 완료: {namespace}/{pod_name}\n"
            f"- quarantine=true 라벨 부착\n"
            f"- NetworkPolicy({netpol_name})로 인바운드/아웃바운드 전면 차단\n"
            f"- 파드 자체는 살려둠(포렌식 조사용). 조사 끝나면 수동으로 삭제하세요."
        ),
    )

    return {"statusCode": 200, "namespace": namespace, "pod": pod_name}
