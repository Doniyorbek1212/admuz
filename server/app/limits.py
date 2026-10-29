"""Request body size cap applied before FastAPI parses forms or JSON."""

from starlette.types import ASGIApp, Message, Receive, Scope, Send


class BodySizeLimit:
    """Answers 413 when a request body is bigger than max_bytes.

    A declared Content-Length is checked up front; chunked bodies are counted as they stream in,
    so a client cannot make the multipart parser buffer an unbounded upload.
    """

    def __init__(self, app: ASGIApp, max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        for name, value in scope.get("headers", []):
            if name == b"content-length":
                try:
                    declared = int(value)
                except ValueError:
                    await _reject(send, 400, b'{"detail":"BAD_CONTENT_LENGTH"}')
                    return
                if declared > self.max_bytes:
                    await _reject(send, 413, b'{"detail":"REQUEST_TOO_LARGE"}')
                    return
        received = 0
        exceeded = False
        responded = False

        async def counted_receive() -> Message:
            nonlocal received, exceeded
            if exceeded:
                return {"type": "http.disconnect"}
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_bytes:
                    # Looks like a dropped client to the app, which stops reading; we answer 413 instead.
                    exceeded = True
                    return {"type": "http.disconnect"}
            return message

        async def guarded_send(message: Message) -> None:
            nonlocal responded
            if exceeded:
                if not responded:
                    responded = True
                    await _reject(send, 413, b'{"detail":"REQUEST_TOO_LARGE"}')
                return
            await send(message)

        try:
            await self.app(scope, counted_receive, guarded_send)
        except Exception:
            # The app fails on the cut-off body (ClientDisconnect); that is the expected end of an oversized request.
            if not exceeded:
                raise
        if exceeded and not responded:
            await _reject(send, 413, b'{"detail":"REQUEST_TOO_LARGE"}')


async def _reject(send: Send, status: int, body: bytes) -> None:
    headers = [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())]
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})
