
import json
import subprocess
import sys
import time

REGION = "ap-northeast-2"
NAME_PREFIX = "demo-project-dev"

LOG_GROUPS = [
    f"/ztna/{NAME_PREFIX}/app-access",
    f"/ztna/{NAME_PREFIX}/db-access",
    f"/ztna/{NAME_PREFIX}/operator-access",
    f"/ztna/{NAME_PREFIX}/login-logout",
]

def aws(*args):
    out = subprocess.run(["aws", *args, "--region", REGION], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr)
    return out.stdout

def main():
    account = sys.argv[1] if len(sys.argv) > 1 else "chulsoo.kim@company.com"
    lookback = int(sys.argv[2]) if len(sys.argv) > 2 else 3600
    now = int(time.time())

    query_id = json.loads(
        aws(
            "logs", "start-query",
            "--log-group-names", *LOG_GROUPS,
            "--start-time", str(now - lookback),
            "--end-time", str(now),
            "--query-string",
            f'fields @timestamp, @log, account, action, subject_processed, access_ip '
            f'| filter account = "{account}" | sort @timestamp asc | limit 100',
            "--output", "json",
        )
    )["queryId"]

    for _ in range(20):
        time.sleep(2)
        result = json.loads(aws("logs", "get-query-results", "--query-id", query_id, "--output", "json"))
        if result["status"] == "Complete":
            rows = result["results"]
            print(f"=== account={account} 통합 타임라인 ({len(rows)}건, 최근 {lookback}s) ===")
            for row in rows:
                fields = {f["field"]: f.get("value", "") for f in row}
                print(f"{fields.get('@timestamp')}  [{fields.get('@log')}]  "
                      f"action={fields.get('action')}  subject={fields.get('subject_processed')}  "
                      f"ip={fields.get('access_ip')}")
            if not rows:
                print("결과 없음 - 아직 해당 계정의 활동이 없거나(③은 5분 스케줄 대기 필요), "
                      "account 값이 로그 그룹마다 실제로 기록된 포맷과 다른지 확인할 것.")
            return
        if result["status"] in ("Failed", "Cancelled", "Timeout"):
            raise RuntimeError(f"query {result['status']}")
    raise TimeoutError("query did not complete in time")

if __name__ == "__main__":
    main()
