import datetime
import json
import os
import time
import boto3

securityhub = boto3.client("securityhub")
logs_client = boto3.client("logs")

CSPM_EXCEPTION_LOG_GROUP = os.environ["CSPM_EXCEPTION_LOG_GROUP"]
DUE_SOON_THRESHOLD_DAYS = int(os.environ.get("DUE_SOON_THRESHOLD_DAYS", "3"))

def _get_active_exceptions() -> list:

    query = (
        "fields eventType, findingId, productArn, resourceId, reviewDate, "
        "ticketRef, approvedBy, reasonType, rationale\n"
        "| filter eventType in ['CSPM_EXCEPTION_RECORDED', 'CSPM_EXCEPTION_CLOSED']\n"
        "| stats latest(eventType) as latestEventType, latest(productArn) as latestProductArn, "
        "latest(resourceId) as latestResourceId, latest(reviewDate) as latestReviewDate, "
        "latest(ticketRef) as latestTicketRef, latest(approvedBy) as latestApprovedBy, "
        "latest(reasonType) as latestReasonType, latest(rationale) as latestRationale by findingId\n"
        "| filter latestEventType = 'CSPM_EXCEPTION_RECORDED'\n"
        "| limit 200"
    )
    start_time = int(time.time() - 90 * 24 * 3600)
    end_time = int(time.time())

    resp = logs_client.start_query(
        logGroupName=CSPM_EXCEPTION_LOG_GROUP,
        startTime=start_time,
        endTime=end_time,
        queryString=query,
    )
    query_id = resp["queryId"]

    while True:
        res = logs_client.get_query_results(queryId=query_id)
        if res["status"] in ["Complete", "Failed", "Cancelled"]:
            break
        time.sleep(1)

    findings = []
    for row in res.get("results", []):
        row_dict = {f["field"]: f["value"] for f in row}
        if "findingId" not in row_dict:
            continue

        findings.append({
            "findingId": row_dict["findingId"],
            "productArn": row_dict.get("latestProductArn", ""),
            "resourceId": row_dict.get("latestResourceId", ""),
            "reviewDate": row_dict.get("latestReviewDate", ""),
            "ticketRef": row_dict.get("latestTicketRef", ""),
            "approvedBy": row_dict.get("latestApprovedBy", ""),
            "reasonType": row_dict.get("latestReasonType", ""),
            "rationale": row_dict.get("latestRationale", ""),
        })
    return findings

def _fetch_findings_by_id(finding_ids: list) -> list:

    findings = []
    for i in range(0, len(finding_ids), 50):
        batch = finding_ids[i : i + 50]
        id_filters = [{"Value": fid, "Comparison": "EQUALS"} for fid in batch]
        next_token = None
        while True:
            kwargs = {"Filters": {"Id": id_filters}, "MaxResults": 100}
            if next_token:
                kwargs["NextToken"] = next_token
            resp = securityhub.get_findings(**kwargs)
            findings.extend(resp.get("Findings", []))
            next_token = resp.get("NextToken")
            if not next_token:
                break
    return findings

def handler(event, context):
    active_exceptions = _get_active_exceptions()
    if not active_exceptions:
        return {"statusCode": 200, "checked": 0, "closed": 0, "dueSoon": 0}

    finding_ids = [item["findingId"] for item in active_exceptions if item.get("findingId")]

    still_open_ids = set(finding_ids)

    closed_events = []
    for finding in _fetch_findings_by_id(finding_ids):
        finding_id = finding.get("Id")
        record_state = finding.get("RecordState")
        compliance = finding.get("Compliance", {}).get("Status")

        if record_state == "ARCHIVED" or compliance == "PASSED":
            closed_events.append({
                "eventType": "CSPM_EXCEPTION_CLOSED",
                "findingId": finding_id,
                "closeReason": "RESOURCE_DELETED" if record_state == "ARCHIVED" else "COMPLIANCE_PASSED",
                "closedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            })
            still_open_ids.discard(finding_id)

    today = datetime.date.today()
    due_soon_events = []
    for item in active_exceptions:
        finding_id = item.get("findingId")
        if not finding_id or finding_id not in still_open_ids:
            continue
        review_date_str = item.get("reviewDate")
        if not review_date_str:
            continue
        try:
            review_date = datetime.date.fromisoformat(review_date_str)
        except ValueError:
            continue
        days_remaining = (review_date - today).days
        if days_remaining <= DUE_SOON_THRESHOLD_DAYS:
            due_soon_events.append({
                "eventType": "CSPM_EXCEPTION_DUE_SOON",
                "findingId": finding_id,
                "reviewDate": review_date_str,
                "daysRemaining": days_remaining,
                "ticketRef": item.get("ticketRef", ""),
                "resourceId": item.get("resourceId", ""),
                "approvedBy": item.get("approvedBy", ""),
                "reasonType": item.get("reasonType", ""),
                "rationale": item.get("rationale", ""),
                "checkedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            })

    all_events = closed_events + due_soon_events
    if all_events:
        log_stream = time.strftime("%Y-%m-%d", time.gmtime())
        try:
            logs_client.create_log_stream(logGroupName=CSPM_EXCEPTION_LOG_GROUP, logStreamName=log_stream)
        except logs_client.exceptions.ResourceAlreadyExistsException:
            pass

        log_payload = [
            {"timestamp": int(time.time() * 1000), "message": json.dumps(ev)}
            for ev in all_events
        ]
        logs_client.put_log_events(
            logGroupName=CSPM_EXCEPTION_LOG_GROUP,
            logStreamName=log_stream,
            logEvents=log_payload,
        )

    return {
        "statusCode": 200,
        "checked": len(active_exceptions),
        "closed": len(closed_events),
        "dueSoon": len(due_soon_events),
    }