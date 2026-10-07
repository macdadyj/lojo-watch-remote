"""Connections and chats stay up until the user ends them.

There is no idle timeout. A heartbeat only keeps the socket open.
"""

IDLE_TIMEOUT = None
HEARTBEAT_SECONDS = 25


def remains_live(elapsed: float, user_ended: bool) -> bool:
    if user_ended:
        return False
    return elapsed >= 0
