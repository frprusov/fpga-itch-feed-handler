-- itch_parser.vhd
-- Byte-stream parser for the ITCH 5.0 subset (SPEC.md sections 2-4).
--
-- Input : one byte per clock cycle (s_axis_tdata / s_axis_tvalid), framed as
--         [len_hi][len_lo][body: len bytes] [len_hi][len_lo][body] ...
-- Output: for every supported message with the correct length, a one-cycle
--         msg_valid pulse with the decoded fields (SPEC 4).
--
-- Structure:
--   * State machine with 3 states:
--       S_LEN_HI  waiting for the high byte of the length prefix
--       S_LEN_LO  waiting for the low byte of the length prefix
--       S_BODY    receiving the message body, offsets 0 .. msg_len-1
--   * Byte counter `idx` = offset of the current byte inside the body.
--     The offsets are exactly those of the SPEC 3 tables.
--   * One register per output field. A field of N bytes is filled by shifting
--     in one byte per cycle while idx is inside its offset range:
--         field_r <= field_r(field_r'high - 8 downto 0) & byte;
--     Big-endian: the first byte that arrives ends up as the most significant.
--   * On the last byte of the body the result is decided:
--         supported type, correct length -> msg_valid pulse
--         supported type, wrong length   -> err_len pulse
--         unsupported type               -> nothing (message skipped)
--
-- Latency: msg_valid is set by the same clock edge that stores the last byte,
-- so the decoded message is available directly after the last byte (0 extra
-- cycles, see test_latency).
--
-- Bytes with s_axis_tvalid = '0' are ignored: nothing changes, so gaps in the
-- stream (also in the middle of a message) do not affect the result.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.itch_pkg.all;

entity itch_parser is
  port (
    clk           : in  std_logic;
    rst           : in  std_logic;
    -- input stream (SPEC 2.3)
    s_axis_tdata  : in  std_logic_vector(7 downto 0);
    s_axis_tvalid : in  std_logic;
    -- decoded message (SPEC 4), valid while msg_valid = '1'
    msg_valid     : out std_logic;
    msg_type      : out std_logic_vector(7 downto 0);
    msg_locate    : out std_logic_vector(15 downto 0);
    msg_timestamp : out std_logic_vector(47 downto 0);
    msg_ref       : out std_logic_vector(63 downto 0);
    msg_new_ref   : out std_logic_vector(63 downto 0);
    msg_side      : out std_logic;                      -- '0' = buy, '1' = sell
    msg_shares    : out std_logic_vector(31 downto 0);
    msg_price     : out std_logic_vector(31 downto 0);
    err_len       : out std_logic                       -- pulse on length mismatch (SPEC 3.7)
  );
end entity itch_parser;

architecture rtl of itch_parser is

  -- State machine ------------------------------------------------------------
  type state_t is (S_LEN_HI, S_LEN_LO, S_BODY);
  signal state : state_t := S_LEN_HI;

  -- Framing ---------------------------------------------------------------------
  signal len_hi  : std_logic_vector(7 downto 0) := (others => '0');  -- first length byte
  signal msg_len : unsigned(15 downto 0) := (others => '0');         -- length of current body
  signal idx     : unsigned(15 downto 0) := (others => '0');         -- offset of current byte

  -- Field registers (one per output) -----------------------------------------
  signal type_r    : std_logic_vector(7 downto 0)  := (others => '0');
  signal locate_r  : std_logic_vector(15 downto 0) := (others => '0');
  signal ts_r      : std_logic_vector(47 downto 0) := (others => '0');
  signal ref_r     : std_logic_vector(63 downto 0) := (others => '0');
  signal new_ref_r : std_logic_vector(63 downto 0) := (others => '0');
  signal side_r    : std_logic := '0';
  signal shares_r  : std_logic_vector(31 downto 0) := (others => '0');
  signal price_r   : std_logic_vector(31 downto 0) := (others => '0');

  -- One-cycle output pulses ----------------------------------------------------
  signal valid_r : std_logic := '0';
  signal err_r   : std_logic := '0';

begin

  process (clk)
    -- Variables get their new value IMMEDIATELY inside the process (signals only
    -- after the clock edge). Used here as short names for the current byte, the
    -- current offset and the type of the current message.
    variable b : std_logic_vector(7 downto 0);  -- current byte
    variable i : natural;                       -- current offset in the body
    variable t : std_logic_vector(7 downto 0);  -- type of the current message
  begin
    if rising_edge(clk) then

      -- Pulses are '0' unless set again below in this cycle.
      valid_r <= '0';
      err_r   <= '0';

      if rst = '1' then
        state <= S_LEN_HI;

      elsif s_axis_tvalid = '1' then
        b := s_axis_tdata;

        case state is

          ----------------------------------------------------------------------
          when S_LEN_HI =>
            len_hi <= b;
            state  <= S_LEN_LO;

          ----------------------------------------------------------------------
          when S_LEN_LO =>
            msg_len <= unsigned(len_hi & b);
            idx     <= (others => '0');
            -- msg_len is a signal: it only has its new value after this edge,
            -- so test the length directly.
            if unsigned(len_hi & b) = 0 then
              state <= S_LEN_HI;  -- empty message: next byte is a new length
            else
              state <= S_BODY;
            end if;

          ----------------------------------------------------------------------
          when S_BODY =>
            i := to_integer(idx);

            -- At offset 0 the type is the current byte; type_r is only updated
            -- after this edge. At later offsets type_r holds it.
            if i = 0 then
              t := b;
            else
              t := type_r;
            end if;

            -- Common header (SPEC 3.1), identical for every message type.
            if i = 0 then
              type_r <= b;
            end if;
            if i >= 1 and i <= 2 then                       -- stock_locate, 2 bytes
              locate_r <= locate_r(7 downto 0) & b;
            end if;
            -- offsets 3-4: tracking number, ignored
            if i >= 5 and i <= 10 then                      -- timestamp, 6 bytes
              ts_r <= ts_r(39 downto 0) & b;
            end if;
            if i >= 11 and i <= 18 then                     -- order_ref, 8 bytes
              ref_r <= ref_r(55 downto 0) & b;
            end if;

            -- Type-specific fields (SPEC 3.2 - 3.6).
            case t is
              when MSG_ADD =>
                if i = 19 then                              -- side, 1 byte
                  if b = SIDE_BYTE_SELL then
                    side_r <= '1';
                  else
                    side_r <= '0';
                  end if;
                end if;
                if i >= 20 and i <= 23 then                 -- shares, 4 bytes
                  shares_r <= shares_r(23 downto 0) & b;
                end if;
                -- offsets 24-31: stock symbol, ignored
                if i >= 32 and i <= 35 then                 -- price, 4 bytes
                  price_r <= price_r(23 downto 0) & b;
                end if;

              when MSG_EXECUTED | MSG_CANCEL =>
                if i >= 19 and i <= 22 then                 -- executed/cancelled shares
                  shares_r <= shares_r(23 downto 0) & b;
                end if;
                -- 'E' offsets 23-30: match number, ignored

              when MSG_REPLACE =>
                if i >= 19 and i <= 26 then                 -- new_order_ref, 8 bytes
                  new_ref_r <= new_ref_r(55 downto 0) & b;
                end if;
                if i >= 27 and i <= 30 then                 -- shares, 4 bytes
                  shares_r <= shares_r(23 downto 0) & b;
                end if;
                if i >= 31 and i <= 34 then                 -- price, 4 bytes
                  price_r <= price_r(23 downto 0) & b;
                end if;

              when others =>
                null;  -- 'D' has no extra fields; unknown types are only counted
            end case;

            -- Last byte of the body: decide and go back to the length prefix.
            if idx = msg_len - 1 then
              state <= S_LEN_HI;
              if expected_len(t) /= 0 then                  -- supported type
                if to_integer(msg_len) = expected_len(t) then
                  valid_r <= '1';
                else
                  err_r <= '1';
                end if;
              end if;
            else
              idx <= idx + 1;
            end if;

        end case;
      end if;
    end if;
  end process;

  -- Outputs: plain wires from the registers ------------------------------------
  msg_valid     <= valid_r;
  err_len       <= err_r;
  msg_type      <= type_r;
  msg_locate    <= locate_r;
  msg_timestamp <= ts_r;
  msg_ref       <= ref_r;
  msg_new_ref   <= new_ref_r;
  msg_side      <= side_r;
  msg_shares    <= shares_r;
  msg_price     <= price_r;

end architecture rtl;
