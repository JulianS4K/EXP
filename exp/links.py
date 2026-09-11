"""Buy-link builders. Rule: a link is emitted only when every stored component is present.
Half a URL is worse than none, because it looks like a working link."""
from __future__ import annotations

from urllib.parse import quote


def vibepass_url(base_url: str | None, event_id: int, section: str | None = None) -> str | None:
    if not base_url:
        return None
    url = f"{base_url.rstrip('/')}/store/event/{int(event_id)}"
    if section:
        url += "?section=" + quote(section, safe="")
    return url


def seatgeek_url(sg_url: str | None, display_id: str | None) -> str | None:
    """Event canonical URL + ``#listing=<display_id>`` — both halves or neither."""
    if not sg_url or not display_id:
        return None
    return f"{sg_url}#listing={display_id}"


def gotickets_url(gt_event_id: int | None, gt_section_id: int | None) -> str | None:
    if gt_event_id is None or gt_section_id is None:
        return None
    return (
        f"https://pro.gotickets.com/tickets/{int(gt_event_id)}/"
        f"?sortBy=price&sortDirection=asc&sections={int(gt_section_id)}"
    )
