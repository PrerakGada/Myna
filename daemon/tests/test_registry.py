from myna.registry import Registry


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def test_add_then_list_shows_item():
    r = Registry()
    rid = r.add("ECS PYQs", "some long text body")
    items = r.list_items()
    assert len(items) == 1
    assert items[0]["id"] == rid
    assert items[0]["label"] == "ECS PYQs"
    assert items[0]["preview"] == "some long text body"
    assert items[0]["age_s"] == 0


def test_pop_returns_and_removes():
    r = Registry()
    rid = r.add("p", "body")
    item = r.pop(rid)
    assert item["text"] == "body"
    assert r.list_items() == []
    assert r.pop(rid) is None


def test_ttl_prunes_old_entries():
    clk = Clock()
    r = Registry(ttl=100, clock=clk)
    r.add("p", "old")
    clk.t += 101
    r.add("p", "new")
    items = r.list_items()
    assert [i["preview"] for i in items] == ["new"]


def test_cap_keeps_only_latest():
    r = Registry(cap=2)
    r.add("p", "a")
    r.add("p", "b")
    r.add("p", "c")
    assert [i["preview"] for i in r.list_items()] == ["b", "c"]
