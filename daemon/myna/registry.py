import time
import uuid


class Registry:
    """Holds silently-announced Claude Code outputs awaiting user playback."""

    def __init__(self, cap: int = 10, ttl: int = 1800, clock=time.time):
        self._items: list[dict] = []
        self.cap = cap
        self.ttl = ttl
        self._clock = clock

    def add(self, label: str, text: str) -> str:
        item = {
            "id": uuid.uuid4().hex[:8],
            "label": label,
            "text": text,
            "created": self._clock(),
        }
        self._items.append(item)
        self.prune()
        return item["id"]

    def prune(self) -> None:
        now = self._clock()
        self._items = [i for i in self._items if now - i["created"] <= self.ttl]
        if len(self._items) > self.cap:
            self._items = self._items[-self.cap:]

    def list_items(self) -> list[dict]:
        self.prune()
        now = self._clock()
        return [
            {
                "id": i["id"],
                "label": i["label"],
                "age_s": int(now - i["created"]),
                "preview": i["text"][:60],
            }
            for i in self._items
        ]

    def pop(self, item_id: str) -> dict | None:
        for idx, i in enumerate(self._items):
            if i["id"] == item_id:
                return self._items.pop(idx)
        return None
