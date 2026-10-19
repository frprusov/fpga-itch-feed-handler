-- order_book.vhd
-- Limit order book for one instrument (SPEC.md section 5).
--
-- Input : the decoded messages from itch_parser (one in_valid pulse per message).
-- Output: after every applied message a one-cycle bbo_valid pulse with the
--         best bid and best ask (top of book) AFTER that message.
--
-- Three pieces of state:
--
--   1. live        1024 flip-flops, one per order reference: is this order live?
--                  Flip-flops (not BRAM) so that a reset clears every order at once.
--
--   2. table       BRAM, 1024 entries of 65 bits: side & price & remaining shares,
--                  addressed by the order reference. Only meaningful where live = '1'.
--                  A read takes one clock cycle, so E/X/D/U need a lookup state.
--
--   3. bids, asks  Price levels per side, kept SORTED in registers, best level at
--                  index 0. The top of book is therefore always entry 0: no search.
--                    - add to an existing price : add to its quantity
--                    - add a new price          : all MAX_LEVELS comparators work in
--                                                 parallel to find the insert position,
--                                                 worse levels shift down one place
--                    - a level reaches 0        : worse levels shift up one place, so
--                                                 the next best level becomes entry 0
--                  All of this happens in a single clock cycle.
--
--                  Each cycle performs at most ONE level operation (add or sub) on
--                  one side. The state machine only decides which one; the level
--                  logic (comparators, shifters) exists once per side. Calling the
--                  level functions from every branch would duplicate that logic for
--                  every call site, which made the first version use ~60% of the LUTs.
--
-- Message handling and latency (rising edges from in_valid to bbo_valid):
--   A        1 cycle   checked against `live` (flip-flops), no table read needed
--   E, X, D  2 cycles  cycle 1: read the table, cycle 2: update order and level
--   U        3 cycles  as D for the original order, then a cycle to insert the new one
--
-- The book needs at most 4 cycles per message, plus 1 for a pending table write.
-- The parser delivers at most one message every 21 cycles (shortest message), so
-- in_valid never arrives while the book is busy. `busy` is an output so the
-- testbench can check that.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.itch_pkg.all;

entity order_book is
  generic (
    LOCATE         : natural  := 1;   -- only messages for this stock_locate are applied
    ORDER_REF_BITS : positive := 10;  -- order references must be < 2**ORDER_REF_BITS
    MAX_LEVELS     : positive := 32   -- price levels per side
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;                      -- synchronous, active high; clears the book
    -- decoded message from the parser (SPEC 4)
    in_valid   : in  std_logic;
    in_type    : in  std_logic_vector(7 downto 0);
    in_locate  : in  std_logic_vector(15 downto 0);
    in_ref     : in  std_logic_vector(63 downto 0);
    in_new_ref : in  std_logic_vector(63 downto 0);
    in_side    : in  std_logic;                      -- '0' = buy, '1' = sell
    in_shares  : in  std_logic_vector(31 downto 0);
    in_price   : in  std_logic_vector(31 downto 0);
    -- status
    busy       : out std_logic;                      -- '1' while a message is being processed
    -- top of book (SPEC 5.5), valid while bbo_valid = '1'
    bbo_valid  : out std_logic;
    bid_valid  : out std_logic;
    bid_price  : out std_logic_vector(31 downto 0);
    bid_qty    : out std_logic_vector(31 downto 0);
    ask_valid  : out std_logic;
    ask_price  : out std_logic_vector(31 downto 0);
    ask_qty    : out std_logic_vector(31 downto 0);
    err_ref    : out std_logic                       -- pulse on invalid input (SPEC 5.4)
  );
end entity order_book;

architecture rtl of order_book is

  constant N_REFS : positive := 2**ORDER_REF_BITS;
  constant RB     : positive := ORDER_REF_BITS;

  ---------------------------------------------------------------------------
  -- Price levels
  ---------------------------------------------------------------------------
  type level_t is record
    price : unsigned(31 downto 0);
    qty   : unsigned(31 downto 0);
  end record;

  constant EMPTY_LEVEL : level_t := (price => (others => '0'), qty => (others => '0'));

  type level_arr_t is array (0 to MAX_LEVELS-1) of level_t;

  -- One side of the book: levels 0 .. count-1 are in use, sorted best first.
  -- Unused entries are always EMPTY_LEVEL.
  type book_side_t is record
    lv    : level_arr_t;
    count : natural range 0 to MAX_LEVELS;
  end record;

  constant EMPTY_SIDE : book_side_t := (lv => (others => EMPTY_LEVEL), count => 0);

  -- Index of the level with price p, or MAX_LEVELS if there is none.
  -- Synthesizes to MAX_LEVELS equality comparators working in parallel.
  function find_level(s : book_side_t; p : unsigned(31 downto 0)) return natural is
    variable r : natural range 0 to MAX_LEVELS := MAX_LEVELS;
  begin
    for i in MAX_LEVELS-1 downto 0 loop
      if i < s.count and s.lv(i).price = p then
        r := i;
      end if;
    end loop;
    return r;
  end function;

  -- Is price a better than price b? Bids: higher is better. Asks: lower is better.
  function better(is_bid : boolean; a, b : unsigned(31 downto 0)) return boolean is
  begin
    if is_bid then
      return a > b;
    else
      return a < b;
    end if;
  end function;

  -- Add q shares at price p. m = find_level(s, p), computed once by the caller.
  -- Caller has checked that a new level fits (side not full, or price exists).
  function level_add(s : book_side_t; is_bid : boolean; m : natural;
                     p, q : unsigned(31 downto 0)) return book_side_t is
    variable r : book_side_t := s;
    variable k : natural range 0 to MAX_LEVELS;
  begin
    if m /= MAX_LEVELS then                    -- price exists: add to its quantity
      r.lv(m).qty := s.lv(m).qty + q;
      return r;
    end if;
    if s.count = MAX_LEVELS then               -- full: should have been checked
      return r;
    end if;
    -- Insert position k = first level that is NOT better than p.
    -- Because the side is sorted, all levels before k are better.
    k := s.count;
    for i in MAX_LEVELS-1 downto 0 loop
      if i < s.count and not better(is_bid, s.lv(i).price, p) then
        k := i;
      end if;
    end loop;
    -- Levels from k onwards move one place down, the new level goes to k.
    for i in MAX_LEVELS-1 downto 1 loop
      if i > k then
        r.lv(i) := s.lv(i-1);
      end if;
    end loop;
    r.lv(k) := (price => p, qty => q);
    r.count := s.count + 1;
    return r;
  end function;

  -- Remove q shares from level m (= find_level(s, price)). A level that reaches 0 is deleted.
  function level_sub(s : book_side_t; m : natural; q : unsigned(31 downto 0)) return book_side_t is
    variable r : book_side_t := s;
  begin
    if m = MAX_LEVELS then                     -- not found: cannot happen for a live order
      return r;
    end if;
    if s.lv(m).qty > q then                    -- level stays
      r.lv(m).qty := s.lv(m).qty - q;
      return r;
    end if;
    -- Level is empty: levels after m move one place up.
    for i in 0 to MAX_LEVELS-2 loop
      if i >= m then
        r.lv(i) := s.lv(i+1);
      end if;
    end loop;
    r.lv(MAX_LEVELS-1) := EMPTY_LEVEL;
    r.count := s.count - 1;
    return r;
  end function;

  ---------------------------------------------------------------------------
  -- Order table (BRAM): side & price & shares
  ---------------------------------------------------------------------------
  type table_t is array (0 to N_REFS-1) of std_logic_vector(64 downto 0);
  signal table     : table_t;
  signal tbl_raddr : unsigned(RB-1 downto 0);
  signal tbl_rdata : std_logic_vector(64 downto 0);
  signal tbl_we    : std_logic := '0';
  signal tbl_waddr : unsigned(RB-1 downto 0) := (others => '0');
  signal tbl_wdata : std_logic_vector(64 downto 0) := (others => '0');

  ---------------------------------------------------------------------------
  -- Control and book state
  ---------------------------------------------------------------------------
  type state_t is (S_IDLE, S_LOOKUP, S_U_INSERT);
  type op_t is (OP_NONE, OP_ADD, OP_SUB);   -- level operation requested this cycle
  signal state : state_t := S_IDLE;

  signal live : std_logic_vector(0 to N_REFS-1) := (others => '0');
  signal bids : book_side_t := EMPTY_SIDE;
  signal asks : book_side_t := EMPTY_SIDE;

  -- Message being processed (latched from the inputs)
  signal m_type       : std_logic_vector(7 downto 0) := (others => '0');
  signal m_ref        : unsigned(RB-1 downto 0) := (others => '0');
  signal m_new_ref    : unsigned(RB-1 downto 0) := (others => '0');
  signal m_new_ref_ok : std_logic := '0';        -- new_ref < 2**ORDER_REF_BITS
  signal m_shares     : unsigned(31 downto 0) := (others => '0');
  signal m_price      : unsigned(31 downto 0) := (others => '0');
  signal u_side       : std_logic := '0';        -- side inherited by the new order of a U

  -- Output registers
  signal bbo_r       : std_logic := '0';
  signal err_r       : std_logic := '0';
  signal bid_valid_r : std_logic := '0';
  signal bid_price_r : unsigned(31 downto 0) := (others => '0');
  signal bid_qty_r   : unsigned(31 downto 0) := (others => '0');
  signal ask_valid_r : std_logic := '0';
  signal ask_price_r : unsigned(31 downto 0) := (others => '0');
  signal ask_qty_r   : unsigned(31 downto 0) := (others => '0');

begin

  ---------------------------------------------------------------------------
  -- Order table: one synchronous read port, one write port.
  -- The read address is always the incoming ref, so the entry of a new message
  -- is available one cycle after in_valid (in state S_LOOKUP).
  ---------------------------------------------------------------------------
  tbl_raddr <= unsigned(in_ref(RB-1 downto 0));

  table_proc : process (clk)
  begin
    if rising_edge(clk) then
      if tbl_we = '1' then
        table(to_integer(tbl_waddr)) <= tbl_wdata;
      end if;
      tbl_rdata <= table(to_integer(tbl_raddr));
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Message processing
  ---------------------------------------------------------------------------
  main_proc : process (clk)
    variable bids_v   : book_side_t;
    variable asks_v   : book_side_t;
    variable emit     : boolean;                 -- pulse bbo_valid this cycle
    -- The one level operation of this cycle
    variable op_kind  : op_t;
    variable op_bid   : boolean;                 -- true: bids, false: asks
    variable op_price : unsigned(31 downto 0);
    variable op_qty   : unsigned(31 downto 0);
    variable mb, ma   : natural range 0 to MAX_LEVELS;  -- index of op_price in bids / asks
    variable full_b   : boolean;                 -- op_price would need a 33rd bid level
    variable full_a   : boolean;                 -- same for asks
    variable is_bid   : boolean;
    variable ref_i    : natural range 0 to N_REFS-1;
    variable new_i    : natural range 0 to N_REFS-1;
    variable o_side   : std_logic;               -- stored order, from the table
    variable o_price  : unsigned(31 downto 0);
    variable o_shares : unsigned(31 downto 0);
    variable amt      : unsigned(31 downto 0);
    variable left_v   : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then

      -- One-cycle pulses default to '0'.
      bbo_r  <= '0';
      err_r  <= '0';
      tbl_we <= '0';

      if rst = '1' then
        state       <= S_IDLE;
        live        <= (others => '0');
        bids        <= EMPTY_SIDE;
        asks        <= EMPTY_SIDE;
        bid_valid_r <= '0';
        bid_price_r <= (others => '0');
        bid_qty_r   <= (others => '0');
        ask_valid_r <= '0';
        ask_price_r <= (others => '0');
        ask_qty_r   <= (others => '0');

      else
        -- Work on copies; written back to the registers at the end of the process.
        bids_v  := bids;
        asks_v  := asks;
        emit    := false;
        op_kind := OP_NONE;
        op_bid  := true;
        op_qty  := (others => '0');

        -- Phase 1: the price this cycle's level operation (if any) works on.
        -- Look it up once per side; the result serves the full check AND the update.
        case state is
          when S_IDLE     => op_price := unsigned(in_price);                -- A
          when S_LOOKUP   => op_price := unsigned(tbl_rdata(63 downto 32)); -- E/X/D/U: stored price
          when S_U_INSERT => op_price := m_price;                           -- new price of a U
        end case;
        mb     := find_level(bids, op_price);
        ma     := find_level(asks, op_price);
        full_b := bids.count = MAX_LEVELS and mb = MAX_LEVELS;
        full_a := asks.count = MAX_LEVELS and ma = MAX_LEVELS;

        -- Phase 2: the state machine decides what happens.

        case state is

          ---------------------------------------------------------------------
          -- Wait for a message. A is handled right here, the others need the table.
          ---------------------------------------------------------------------
          when S_IDLE =>
            if in_valid = '1' then
              m_type    <= in_type;
              m_ref     <= unsigned(in_ref(RB-1 downto 0));
              m_new_ref <= unsigned(in_new_ref(RB-1 downto 0));
              m_shares  <= unsigned(in_shares);
              m_price   <= unsigned(in_price);
              if unsigned(in_new_ref(63 downto RB)) = 0 then
                m_new_ref_ok <= '1';
              else
                m_new_ref_ok <= '0';
              end if;

              ref_i  := to_integer(unsigned(in_ref(RB-1 downto 0)));
              is_bid := in_side = '0';

              if unsigned(in_locate) /= LOCATE then
                null;                                         -- other instrument: ignore silently

              elsif unsigned(in_ref(63 downto RB)) /= 0 then
                err_r <= '1';                                 -- ref out of range

              elsif in_type = MSG_ADD then
                if live(ref_i) = '1' then
                  err_r <= '1';                               -- ref already live
                elsif (is_bid and full_b) or (not is_bid and full_a) then
                  err_r <= '1';                               -- no room for a new level
                else
                  live(ref_i) <= '1';
                  tbl_we    <= '1';
                  tbl_waddr <= unsigned(in_ref(RB-1 downto 0));
                  tbl_wdata <= in_side & in_price & in_shares;
                  op_kind   := OP_ADD;
                  op_bid    := is_bid;
                  op_qty    := unsigned(in_shares);
                  emit      := true;
                end if;

              elsif in_type = MSG_EXECUTED or in_type = MSG_CANCEL or
                    in_type = MSG_DELETE or in_type = MSG_REPLACE then
                state <= S_LOOKUP;                            -- table entry arrives next cycle
              end if;
            end if;

          ---------------------------------------------------------------------
          -- Table entry of m_ref is now in tbl_rdata.
          ---------------------------------------------------------------------
          when S_LOOKUP =>
            state    <= S_IDLE;
            ref_i    := to_integer(m_ref);
            new_i    := to_integer(m_new_ref);
            o_side   := tbl_rdata(64);
            o_price  := unsigned(tbl_rdata(63 downto 32));
            o_shares := unsigned(tbl_rdata(31 downto 0));
            is_bid   := o_side = '0';

            if live(ref_i) = '0' then
              err_r <= '1';                                   -- unknown order

            elsif m_type = MSG_EXECUTED or m_type = MSG_CANCEL then
              -- Saturate: never remove more than the order has (SPEC 5.4).
              if m_shares > o_shares then
                amt   := o_shares;
                err_r <= '1';
              else
                amt := m_shares;
              end if;
              left_v := o_shares - amt;
              if left_v = 0 then
                live(ref_i) <= '0';                           -- order fully gone
              else
                tbl_we    <= '1';                             -- store remaining shares
                tbl_waddr <= m_ref;
                tbl_wdata <= o_side & std_logic_vector(o_price) & std_logic_vector(left_v);
              end if;
              op_kind := OP_SUB;
              op_bid  := is_bid;
              op_qty  := amt;
              emit    := true;

            elsif m_type = MSG_DELETE then
              live(ref_i) <= '0';
              op_kind := OP_SUB;
              op_bid  := is_bid;
              op_qty  := o_shares;
              emit    := true;

            elsif m_type = MSG_REPLACE then
              if m_new_ref_ok = '0' or (m_new_ref /= m_ref and live(new_i) = '1') then
                err_r <= '1';                                 -- invalid new ref: book unchanged
              else
                live(ref_i) <= '0';                           -- remove the original order
                op_kind := OP_SUB;
                op_bid  := is_bid;
                op_qty  := o_shares;
                u_side <= o_side;                             -- new order inherits the side
                state  <= S_U_INSERT;
              end if;
            end if;

          ---------------------------------------------------------------------
          -- Second half of a U: insert the new order (levels already updated).
          ---------------------------------------------------------------------
          when S_U_INSERT =>
            state  <= S_IDLE;
            new_i  := to_integer(m_new_ref);
            is_bid := u_side = '0';

            if (is_bid and full_b) or (not is_bid and full_a) then
              err_r <= '1';                                   -- no room: original stays removed
            else
              live(new_i) <= '1';
              tbl_we    <= '1';
              tbl_waddr <= m_new_ref;
              tbl_wdata <= u_side & std_logic_vector(m_price) & std_logic_vector(m_shares);
              op_kind   := OP_ADD;
              op_bid    := is_bid;
              op_qty    := m_shares;
            end if;
            emit := true;

        end case;

        -- Phase 3: apply the one level operation. One adder/shifter per side.
        if op_kind = OP_ADD then
          if op_bid then
            bids_v := level_add(bids, true, mb, op_price, op_qty);
          else
            asks_v := level_add(asks, false, ma, op_price, op_qty);
          end if;
        elsif op_kind = OP_SUB then
          if op_bid then
            bids_v := level_sub(bids, mb, op_qty);
          else
            asks_v := level_sub(asks, ma, op_qty);
          end if;
        end if;

        -- Write back the book and publish the top of book.
        bids <= bids_v;
        asks <= asks_v;
        if emit then
          bbo_r <= '1';
          if bids_v.count > 0 then
            bid_valid_r <= '1';
            bid_price_r <= bids_v.lv(0).price;
            bid_qty_r   <= bids_v.lv(0).qty;
          else
            bid_valid_r <= '0';
            bid_price_r <= (others => '0');
            bid_qty_r   <= (others => '0');
          end if;
          if asks_v.count > 0 then
            ask_valid_r <= '1';
            ask_price_r <= asks_v.lv(0).price;
            ask_qty_r   <= asks_v.lv(0).qty;
          else
            ask_valid_r <= '0';
            ask_price_r <= (others => '0');
            ask_qty_r   <= (others => '0');
          end if;
        end if;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Outputs
  ---------------------------------------------------------------------------
  busy      <= '1' when state /= S_IDLE or tbl_we = '1' else '0';
  bbo_valid <= bbo_r;
  err_ref   <= err_r;
  bid_valid <= bid_valid_r;
  bid_price <= std_logic_vector(bid_price_r);
  bid_qty   <= std_logic_vector(bid_qty_r);
  ask_valid <= ask_valid_r;
  ask_price <= std_logic_vector(ask_price_r);
  ask_qty   <= std_logic_vector(ask_qty_r);

end architecture rtl;
