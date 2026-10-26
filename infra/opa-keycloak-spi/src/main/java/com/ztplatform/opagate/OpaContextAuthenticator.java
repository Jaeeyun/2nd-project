package com.ztplatform.opagate;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.jboss.logging.Logger;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.Authenticator;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

import java.net.URI;
import java.net.URLDecoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class OpaContextAuthenticator implements Authenticator {

    private static final Logger logger = Logger.getLogger(OpaContextAuthenticator.class);
    private static final String OPA_URL = System.getenv().getOrDefault(
            "OPA_URL", "http://host.docker.internal:8181/v1/data/login_context/allow");
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(2))
            .build();

    private static final Pattern CN_PATTERN = Pattern.compile("CN=([^,]+)");

    @Override
    public void authenticate(AuthenticationFlowContext context) {
        UserModel user = context.getUser();
        String username = user != null ? user.getUsername() : "unknown";
        String sourceIp = context.getConnection().getRemoteAddr();
        String deviceCn = extractDeviceCn(context);

        boolean allow;
        try {
            allow = queryOpa(username, sourceIp, deviceCn);
        } catch (Exception e) {

            logger.errorf(e, "OPA 정책 조회 실패 - fail-closed로 로그인 거부 (user=%s)", username);
            context.getEvent().detail("opa_gate", "error:" + e.getClass().getSimpleName());
            context.failure(AuthenticationFlowError.ACCESS_DENIED);
            return;
        }

        context.getEvent().detail("opa_gate", allow ? "allow" : "deny");
        if (allow) {
            context.success();
        } else {
            logger.warnf("OPA 로그인 컨텍스트 게이트 거부: user=%s ip=%s", username, sourceIp);
            context.failure(AuthenticationFlowError.ACCESS_DENIED);
        }
    }

    private String extractDeviceCn(AuthenticationFlowContext context) {
        if (context.getHttpRequest() == null) {
            return "";
        }
        String subject = context.getHttpRequest().getHttpHeaders()
                .getHeaderString("X-Amzn-Mtls-Clientcert-Subject");
        if (subject == null || subject.isEmpty()) {
            return "";
        }
        try {
            subject = URLDecoder.decode(subject, StandardCharsets.UTF_8);
        } catch (Exception ignored) {

        }
        Matcher m = CN_PATTERN.matcher(subject);
        return m.find() ? m.group(1) : "";
    }

    private boolean queryOpa(String username, String sourceIp, String deviceCn) throws Exception {
        Map<String, Object> input = new HashMap<>();
        input.put("username", username);
        input.put("source_ip", sourceIp);
        input.put("device_cn", deviceCn);
        Map<String, Object> body = new HashMap<>();
        body.put("input", input);

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(OPA_URL))
                .timeout(Duration.ofSeconds(3))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(MAPPER.writeValueAsString(body)))
                .build();

        HttpResponse<String> response = HTTP.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() != 200) {
            throw new IllegalStateException("OPA HTTP " + response.statusCode());
        }
        JsonNode root = MAPPER.readTree(response.body());
        JsonNode result = root.get("result");
        return result != null && result.asBoolean(false);
    }

    @Override
    public void action(AuthenticationFlowContext context) {

    }

    @Override
    public boolean requiresUser() {
        return true;
    }

    @Override
    public boolean configuredFor(KeycloakSession session, RealmModel realm, UserModel user) {
        return true;
    }

    @Override
    public void setRequiredActions(KeycloakSession session, RealmModel realm, UserModel user) {

    }

    @Override
    public void close() {

    }
}
