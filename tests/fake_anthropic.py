"""A scripted stand-in for the Anthropic client. No network, no key."""
from types import SimpleNamespace as NS


def text(t):
    return NS(type="text", text=t)


def tool_use(tool_id, tool_name, **inputs):
    # parameters are named so that a tool input called "name" can be passed
    return NS(type="tool_use", id=tool_id, name=tool_name, input=inputs)


def resp(content, stop="end_turn", inp=100, out=20):
    return NS(content=content, stop_reason=stop,
              usage=NS(input_tokens=inp, output_tokens=out))


class FakeClient:
    """``client.messages.create(...)`` returns the scripted responses in order.

    An item may be an Exception (raised) or a callable (called with the
    request kwargs, returning a response).
    """

    def __init__(self, script, hook=None):
        self.script = list(script)
        self.calls = []
        self.hook = hook
        self.messages = self

    def create(self, **kwargs):
        snapshot = dict(kwargs)
        snapshot["messages"] = list(kwargs["messages"])
        self.calls.append(snapshot)
        if self.hook:
            self.hook(len(self.calls))
        item = self.script.pop(0)
        if isinstance(item, Exception):
            raise item
        return item(kwargs) if callable(item) else item
