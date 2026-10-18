-- itch_pkg.vhd
-- Shared constants for the ITCH feed handler (SPEC.md sections 2-4).
--
-- A package contains no hardware: only definitions that several design
-- units use. Use it with:   use work.itch_pkg.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package itch_pkg is

  -- Message type bytes (ASCII), SPEC 3
  constant MSG_ADD      : std_logic_vector(7 downto 0) := x"41";  -- 'A'
  constant MSG_EXECUTED : std_logic_vector(7 downto 0) := x"45";  -- 'E'
  constant MSG_CANCEL   : std_logic_vector(7 downto 0) := x"58";  -- 'X'
  constant MSG_DELETE   : std_logic_vector(7 downto 0) := x"44";  -- 'D'
  constant MSG_REPLACE  : std_logic_vector(7 downto 0) := x"55";  -- 'U'

  -- Message lengths in bytes, without the 2-byte length prefix, SPEC 3
  constant LEN_ADD      : natural := 36;
  constant LEN_EXECUTED : natural := 31;
  constant LEN_CANCEL   : natural := 23;
  constant LEN_DELETE   : natural := 19;
  constant LEN_REPLACE  : natural := 35;

  -- Side byte (ASCII) in an Add Order, SPEC 3.2
  constant SIDE_BYTE_BUY  : std_logic_vector(7 downto 0) := x"42";  -- 'B'
  constant SIDE_BYTE_SELL : std_logic_vector(7 downto 0) := x"53";  -- 'S'

  -- Returns the expected message length for a supported type, 0 otherwise.
  function expected_len(msg_type : std_logic_vector(7 downto 0)) return natural;

end package itch_pkg;

package body itch_pkg is

  function expected_len(msg_type : std_logic_vector(7 downto 0)) return natural is
  begin
    case msg_type is
      when MSG_ADD      => return LEN_ADD;
      when MSG_EXECUTED => return LEN_EXECUTED;
      when MSG_CANCEL   => return LEN_CANCEL;
      when MSG_DELETE   => return LEN_DELETE;
      when MSG_REPLACE  => return LEN_REPLACE;
      when others       => return 0;
    end case;
  end function;

end package body itch_pkg;
