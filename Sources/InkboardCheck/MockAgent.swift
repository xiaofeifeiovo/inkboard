// Kept out of main.swift: globals there are initialised in statement order, after the checks run.
/// A scripted ACP agent for the client checks.
let mockAgentSource = #"""
import sys, json
sessions = {}
serial = 0
permissions = {}
permission_id = 900
def levels(state):
    return ["low", "high"] if state["model"] == "alpha" else ["low"]
def options(state):
    return [
        {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": state["model"],
         "options": [{"value": "alpha", "name": "Alpha"},
                     {"group": "more", "name": "More", "options": [{"value": "beta", "name": "Beta"}]}]},
        {"id": "thought_level", "name": "Thinking", "category": "thought_level", "type": "select",
         "currentValue": state["level"], "options": [{"value": v, "name": v.title()} for v in levels(state)]},
    ]
def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()
def chunk(sid, text):
    send({"jsonrpc": "2.0", "method": "session/update",
          "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk",
                                                    "content": {"type": "text", "text": text}}}})
waiting = {}
for line in sys.stdin:
    m = json.loads(line)
    method, mid, p = m.get("method"), m.get("id"), m.get("params", {})
    sid = p.get("sessionId")
    state = sessions.get(sid)
    if method is None and mid in permissions:
        sid, request_id, images, turn = permissions.pop(mid)
        state = sessions[sid]
        outcome = m["result"]["outcome"]
        chunk(sid, "```latex\n")
        chunk(sid, "model=%s level=%s images=%d permission=%s" % (state["model"], state["level"], images,
                                                                  outcome.get("optionId", outcome["outcome"])))
        if turn > 1:
            chunk(sid, " turn=%d" % turn)
        chunk(sid, "\n```")
        send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": "end_turn"}})
    elif method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1,
              "agentCapabilities": {"promptCapabilities": {"image": True}, "sessionCapabilities": {"close": {}}}}})
    elif method == "session/new":
        serial += 1
        sid = "s%d" % serial
        state = sessions[sid] = {"model": "alpha", "level": "low", "turn": 0}
        send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": sid, "configOptions": options(state)}})
    elif method == "session/set_config_option":
        if p["configId"] == "model":
            if p["value"] not in ("alpha", "beta"):
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "bad model"}})
                continue
            state["model"] = p["value"]
            if state["level"] not in levels(state):
                state["level"] = "low"
        else:
            state["level"] = p["value"]
        send({"jsonrpc": "2.0", "id": mid, "result": {"configOptions": options(state)}})
    elif method == "session/prompt":
        state["turn"] += 1
        blocks = p["prompt"]
        text = blocks[0]["text"]
        if text == "SLOW":
            waiting[sid] = mid
            continue
        if text == "CRASH":
            sys.stderr.write("mock agent crashed\n")
            sys.stderr.flush()
            sys.exit(3)
        images = sum(1 for b in blocks if b["type"] == "image")
        permission_id += 1
        permissions[permission_id] = (sid, mid, images, state["turn"])
        send({"jsonrpc": "2.0", "id": permission_id, "method": "session/request_permission",
              "params": {"sessionId": sid, "toolCall": {"toolCallId": "t1"},
                         "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"},
                                     {"optionId": "no", "name": "Reject", "kind": "reject_once"}]}})
    elif method == "session/cancel":
        if sid in waiting:
            send({"jsonrpc": "2.0", "id": waiting.pop(sid), "result": {"stopReason": "cancelled"}})
    elif method == "session/close":
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown method"}})
"""#
