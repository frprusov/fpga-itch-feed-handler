"""Print the SPEC 7.2 scenario step by step. Run from the repo root:

    python -m model.demo
"""

from .itch import encode_body, encode_stream, frame, parse_stream
from .order_book import OrderBook
from .scenarios import SCENARIO_7_2


def main() -> None:
    book = OrderBook()
    parsed = parse_stream(encode_stream(SCENARIO_7_2))
    for i, (msg, p) in enumerate(zip(SCENARIO_7_2, parsed.msgs, strict=True), start=1):
        raw = frame(encode_body(msg))
        result = book.apply(p)
        print(f"{i}. {p.msg_type} ref={p.ref:<3} ({len(raw)} bytes)  ->  {result.bbo}")
    print()
    print("Bytes of message 1:")
    print(" ".join(f"{b:02X}" for b in frame(encode_body(SCENARIO_7_2[0]))))


if __name__ == "__main__":
    main()
