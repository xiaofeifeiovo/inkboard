// Kept out of main.swift: globals there are initialised in statement order, after the checks run.
/// A scripted ACP agent for the client checks.
let mockAgentSource = #"""
import sys, json
state = {"model": "alpha", "level": "low"}
def levels():
    return ["low", "high"] if state["model"] == "alpha" else ["low"]
def options():
    return [
        {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": state["model"],
         "options": [{"value": "alpha", "name": "Alpha"},
                     {"group": "more", "name": "More", "options": [{"value": "beta", "name": "Beta"}]}]},
        {"id": "thought_level", "name": "Thinking", "category": "thought_level", "type": "select",
         "currentValue": state["level"], "options": [{"value": v, "name": v.title()} for v in levels()]},
    ]
def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()
def chunk(text):
    send({"jsonrpc": "2.0", "method": "session/update",
          "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk",
                                                    "content": {"type": "text", "text": text}}}})
waiting = None
for line in sys.stdin:
    m = json.loads(line)
    method, mid, p = m.get("method"), m.get("id"), m.get("params", {})
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1,
              "agentCapabilities": {"promptCapabilities": {"image": True}, "sessionCapabilities": {"close": {}}}}})
    elif method == "session/new":
        state["model"], state["level"] = "alpha", "low"
        send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "s1", "configOptions": options()}})
    elif method == "session/set_config_option":
        if p["configId"] == "model":
            if p["value"] not in ("alpha", "beta"):
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "bad model"}})
                continue
            state["model"] = p["value"]
            if state["level"] not in levels():
                state["level"] = "low"
        else:
            state["level"] = p["value"]
        send({"jsonrpc": "2.0", "id": mid, "result": {"configOptions": options()}})
    elif method == "session/prompt":
        blocks = p["prompt"]
        text = blocks[0]["text"]
        if text == "SLOW":
            waiting = mid
            continue
        if text == "CRASH":
            sys.stderr.write("mock agent crashed\n")
            sys.stderr.flush()
            sys.exit(3)
        send({"jsonrpc": "2.0", "id": 900, "method": "session/request_permission",
              "params": {"sessionId": "s1", "toolCall": {"toolCallId": "t1"},
                         "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"},
                                     {"optionId": "no", "name": "Reject", "kind": "reject_once"}]}})
        outcome = json.loads(sys.stdin.readline())["result"]["outcome"]
        images = sum(1 for b in blocks if b["type"] == "image")
        chunk("```latex\n")
        chunk("model=%s level=%s images=%d permission=%s" % (state["model"], state["level"], images,
                                                            outcome.get("optionId", outcome["outcome"])))
        chunk("\n```")
        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    elif method == "session/cancel":
        if waiting is not None:
            send({"jsonrpc": "2.0", "id": waiting, "result": {"stopReason": "cancelled"}})
            waiting = None
    elif method == "session/close":
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown method"}})
"""#
