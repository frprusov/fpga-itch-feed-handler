library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity counter is
  generic (
    WIDTH : positive := 8
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;  -- synchrone reset, actief hoog
    en    : in  std_logic;  -- tellen alleen als en = '1'
    count : out std_logic_vector(WIDTH-1 downto 0)
  );
end entity counter;

architecture rtl of counter is
  signal cnt : unsigned(WIDTH-1 downto 0) := (others => '0');
begin

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cnt <= (others => '0');
      elsif en = '1' then
        cnt <= cnt + 1;
      end if;
    end if;
  end process;

  count <= std_logic_vector(cnt);

end architecture rtl;