"""Hand-written scenarios with known expected results (SPEC 7).

Used by the pytest tests of the model and, later, by the cocotb testbenches.
"""

from .itch import SIDE_BUY, SIDE_SELL, AddOrder, OrderCancel, OrderDelete, OrderExecuted, OrderReplace
from .order_book import BBO

TS_0930 = 34_200_000_000_000  # 09:30:00.000000000

# SPEC 7.1: the first message, byte by byte.
ADD_ORDER_EXAMPLE = AddOrder(order_ref=42, side=SIDE_BUY, shares=100, price=1_892_500, timestamp=TS_0930)
ADD_ORDER_EXAMPLE_BYTES = bytes.fromhex(
    "0024"
    "41"
    "0001"
    "0000"
    "1F1ACED9F000"
    "000000000000002A"
    "42"
    "00000064"
    "4141504C20202020"
    "001CE094"
)

# SPEC 7.2: seven-message scenario and the expected top of book after each message.
SCENARIO_7_2 = [
    ADD_ORDER_EXAMPLE,
    AddOrder(43, SIDE_BUY, 200, 1_893_000, timestamp=TS_0930 + 1),
    AddOrder(44, SIDE_SELL, 150, 1_894_000, timestamp=TS_0930 + 2),
    OrderExecuted(43, 30, match_number=1, timestamp=TS_0930 + 3),
    OrderCancel(44, 50, timestamp=TS_0930 + 4),
    OrderReplace(43, 45, 300, 1_892_600, timestamp=TS_0930 + 5),
    OrderDelete(45, timestamp=TS_0930 + 6),
]

_NONE = (False, 0, 0)

SCENARIO_7_2_EXPECTED = [
    BBO(True, 1_892_500, 100, *_NONE),
    BBO(True, 1_893_000, 200, *_NONE),
    BBO(True, 1_893_000, 200, True, 1_894_000, 150),
    BBO(True, 1_893_000, 170, True, 1_894_000, 150),
    BBO(True, 1_893_000, 170, True, 1_894_000, 100),
    BBO(True, 1_892_600, 300, True, 1_894_000, 100),
    BBO(True, 1_892_500, 100, True, 1_894_000, 100),
]
