
package login_context

import future.keywords.if
import future.keywords.in

default allow := false

allowed_cidrs := split(opa.runtime().env.OPERATOR_ALLOWED_CIDRS, ",")

allow if {
	source_ip_allowed
	device_currently_trusted
}

source_ip_allowed if {
	some cidr in allowed_cidrs
	net.cidr_contains(cidr, input.source_ip)
}

device_currently_trusted if {
	input.device_cn != ""
	resp := http.send({
		"method": "GET",
		"url": sprintf("%s?device_cn=%s", [opa.runtime().env.DEVICE_POSTURE_LOOKUP_URL, input.device_cn]),
		"headers": {"x-api-key": opa.runtime().env.DEVICE_POSTURE_LOOKUP_API_KEY},
		"force_cache": false,
		"timeout": "2s",
	})
	resp.status_code == 200
	resp.body.trusted == true
}

deny_reason := reason if {
	not source_ip_allowed
	not device_currently_trusted
	reason := "허용되지 않은 네트워크 대역 + 디바이스 신뢰 불가"
} else := reason if {
	not source_ip_allowed
	reason := "허용되지 않은 네트워크 대역"
} else := reason if {
	not device_currently_trusted
	reason := "디바이스 신뢰 불가(8443 mTLS 포트로 접속했는지, device-posture-lookup 조회 결과 확인)"
} else := "" if {
	allow
}
