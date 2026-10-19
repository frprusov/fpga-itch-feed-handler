-- feed_handler.vhd
-- Top level: ITCH byte stream in, top of book out (SPEC.md).
--
--   s_axis_tdata ──► itch_parser ──msg_*──► order_book ──► bid/ask, bbo_valid
--   s_axis_tvalid                                          err_len, err_ref
--
-- Purely structural: two instances and the wires between them, no logic.
--
-- End-to-end latency, from the clock edge that consumes the last byte of a
-- message to the edge that sets bbo_valid:
--   parser 0 cycles + order book (A 1, E/X/D 2, U 3) = A 1, E/X/D 2, U 3 cycles.

library ieee;
use ieee.std_logic_1164.all;

entity feed_handler is
  generic (
    LOCATE         : natural  := 1;
    ORDER_REF_BITS : positive := 10;
    MAX_LEVELS     : positive := 32
  );
  port (
    clk           : in  std_logic;
    rst           : in  std_logic;                      -- synchronous, active high
    -- input stream (SPEC 2.3)
    s_axis_tdata  : in  std_logic_vector(7 downto 0);
    s_axis_tvalid : in  std_logic;
    -- top of book (SPEC 5.5)
    bbo_valid     : out std_logic;
    bid_valid     : out std_logic;
    bid_price     : out std_logic_vector(31 downto 0);
    bid_qty       : out std_logic_vector(31 downto 0);
    ask_valid     : out std_logic;
    ask_price     : out std_logic_vector(31 downto 0);
    ask_qty       : out std_logic_vector(31 downto 0);
    -- error pulses
    err_len       : out std_logic;                      -- from the parser (SPEC 3.7)
    err_ref       : out std_logic                       -- from the order book (SPEC 5.4)
  );
end entity feed_handler;

architecture structural of feed_handler is

  -- Wires between parser and order book
  signal msg_valid   : std_logic;
  signal msg_type    : std_logic_vector(7 downto 0);
  signal msg_locate  : std_logic_vector(15 downto 0);
  signal msg_ref     : std_logic_vector(63 downto 0);
  signal msg_new_ref : std_logic_vector(63 downto 0);
  signal msg_side    : std_logic;
  signal msg_shares  : std_logic_vector(31 downto 0);
  signal msg_price   : std_logic_vector(31 downto 0);
  signal book_busy   : std_logic;

begin

  parser : entity work.itch_parser
    port map (
      clk           => clk,
      rst           => rst,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      msg_valid     => msg_valid,
      msg_type      => msg_type,
      msg_locate    => msg_locate,
      msg_timestamp => open,             -- not used by the order book
      msg_ref       => msg_ref,
      msg_new_ref   => msg_new_ref,
      msg_side      => msg_side,
      msg_shares    => msg_shares,
      msg_price     => msg_price,
      err_len       => err_len
    );

  book : entity work.order_book
    generic map (
      LOCATE         => LOCATE,
      ORDER_REF_BITS => ORDER_REF_BITS,
      MAX_LEVELS     => MAX_LEVELS
    )
    port map (
      clk        => clk,
      rst        => rst,
      in_valid   => msg_valid,
      in_type    => msg_type,
      in_locate  => msg_locate,
      in_ref     => msg_ref,
      in_new_ref => msg_new_ref,
      in_side    => msg_side,
      in_shares  => msg_shares,
      in_price   => msg_price,
      busy       => book_busy,
      bbo_valid  => bbo_valid,
      bid_valid  => bid_valid,
      bid_price  => bid_price,
      bid_qty    => bid_qty,
      ask_valid  => ask_valid,
      ask_price  => ask_price,
      ask_qty    => ask_qty,
      err_ref    => err_ref
    );

  -- Simulation-only check (ignored by synthesis): the parser delivers at most one
  -- message every 21 cycles and the book needs at most 4, so this must never fire.
  -- synthesis translate_off
  process (clk)
  begin
    if rising_edge(clk) then
      assert not (msg_valid = '1' and book_busy = '1')
        report "feed_handler: message arrived while the order book was busy"
        severity error;
    end if;
  end process;
  -- synthesis translate_on

end architecture structural;
