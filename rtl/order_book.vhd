-- order_book.vhd  (v2, pipelined)
-- Limit order book for one instrument (SPEC.md section 5).
--
-- Input : the decoded messages from itch_parser (one in_valid pulse per message).
-- Output: after every applied message a one-cycle bbo_valid pulse with the
--         best bid and best ask (top of book) AFTER that message.
--
-- State:
--   live        1024 flip-flops, one per order reference: is this order live?
--               Flip-flops (not BRAM) so that a reset clears every order at once.
--   table       BRAM, 1024 x 65 bits: side & price & remaining shares per order ref.
--               Read with the BRAM output register: data arrives 2 cycles after the
--               address (S_READ, then S_DECIDE).
--   bids, asks  Price levels per side, SORTED in registers, best level at index 0,
--               so the top of book is always entry 0.
--
-- v1 did a whole message in 1-3 long cycles and reached ~51 MHz: one path went
-- BRAM -> price compare -> insert position -> shift all levels -> top of book.
-- v2 cuts that path into short stages, each ending in registers:
--
--   S_IDLE    latch the message; checks that need no table (locate, ref range,
--             duplicate A via `live`)
--   S_READ    wait for the BRAM output register                    (E/X/D/U)
--   S_DECIDE  stored order is available: validate, compute the level operation
--   S_FIND    compare the operation's price with all levels of its side in
--             parallel; register the results as bit vectors (match, better, ...)
--             and the new quantity
--   S_APPLY   update the levels using only those registered vectors (shallow
--             muxes) and publish the new top of book directly from entry 0
--
-- Latency (rising edges from in_valid to bbo_valid):
--   A 3 (IDLE, FIND, APPLY)   E/X/D 5   U 7 (remove old, then FIND+APPLY for the new)
--
-- The book is busy at most 8 cycles per message. The parser delivers at most one
-- message every 21 cycles (shortest message), so in_valid never arrives while the
-- book is busy. `busy` is an output so the testbench can check that.

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

  -- One bit per level, index 0 = best level.
  subtype lvl_vec_t is std_logic_vector(0 to MAX_LEVELS-1);

  type op_t is (OP_NONE, OP_ADD, OP_SUB);

  -- Bit i = '1' if level i is in use and has price p (at most one bit set).
  function match_vec(s : book_side_t; p : unsigned(31 downto 0)) return lvl_vec_t is
    variable v : lvl_vec_t := (others => '0');
  begin
    for i in 0 to MAX_LEVELS-1 loop
      if i < s.count and s.lv(i).price = p then
        v(i) := '1';
      end if;
    end loop;
    return v;
  end function;

  -- Bit i = '1' if level i is in use and better than price p.
  -- The side is sorted, so this is a run of ones: 1..1 0..0.
  function better_vec(s : book_side_t; is_bid : boolean;
                      p : unsigned(31 downto 0)) return lvl_vec_t is
    variable v : lvl_vec_t := (others => '0');
  begin
    for i in 0 to MAX_LEVELS-1 loop
      if i < s.count then
        if (is_bid and s.lv(i).price > p) or (not is_bid and s.lv(i).price < p) then
          v(i) := '1';
        end if;
      end if;
    end loop;
    return v;
  end function;

  -- Bit i = '1' if any of bits 0 .. i is set (marks the match and everything after it).
  function prefix_or(v : lvl_vec_t) return lvl_vec_t is
    variable r   : lvl_vec_t;
    variable acc : std_logic := '0';
  begin
    for i in 0 to MAX_LEVELS-1 loop
      acc  := acc or v(i);
      r(i) := acc;
    end loop;
    return r;
  end function;

  function any(v : lvl_vec_t) return boolean is
  begin
    return v /= (v'range => '0');
  end function;

  -- Quantity of the matching level (0 if none): an AND-OR tree, no index decoding.
  function match_qty(s : book_side_t; m : lvl_vec_t) return unsigned is
    variable q : unsigned(31 downto 0) := (others => '0');
  begin
    for i in 0 to MAX_LEVELS-1 loop
      if m(i) = '1' then
        q := q or s.lv(i).qty;
      end if;
    end loop;
    return q;
  end function;

  -- Apply one level operation. All decisions were made in S_FIND and come in as
  -- registered bit vectors, so this is only a small multiplexer per register bit.
  --   ADD, found     : level with match = '1' gets quantity newq
  --   ADD, not found : insert (p, q) after the levels that are better
  --   SUB, not rm    : level with match = '1' gets quantity newq
  --   SUB, rm        : remove the matching level, worse levels move up
  function level_apply(s : book_side_t; op : op_t; found, rm : boolean;
                       m, b, geq : lvl_vec_t;
                       p, q, newq : unsigned(31 downto 0)) return book_side_t is
    variable r : book_side_t := s;
  begin
    if (op = OP_ADD and found) or (op = OP_SUB and not rm) then
      for i in 0 to MAX_LEVELS-1 loop
        if m(i) = '1' then
          r.lv(i).qty := newq;
        end if;
      end loop;

    elsif op = OP_ADD then                              -- insert a new level
      if b(0) = '0' then
        r.lv(0) := (price => p, qty => q);
      end if;
      for i in 1 to MAX_LEVELS-1 loop
        if b(i) = '0' then
          if b(i-1) = '1' then
            r.lv(i) := (price => p, qty => q);          -- first level that is not better
          else
            r.lv(i) := s.lv(i-1);                       -- everything after it moves down
          end if;
        end if;
      end loop;
      r.count := s.count + 1;

    elsif op = OP_SUB then                              -- remove a level
      for i in 0 to MAX_LEVELS-2 loop
        if geq(i) = '1' then
          r.lv(i) := s.lv(i+1);
        end if;
      end loop;
      if geq(MAX_LEVELS-1) = '1' then
        r.lv(MAX_LEVELS-1) := EMPTY_LEVEL;
      end if;
      r.count := s.count - 1;
    end if;
    return r;
  end function;

  ---------------------------------------------------------------------------
  -- Order table (BRAM): side & price & shares
  ---------------------------------------------------------------------------
  type table_t is array (0 to N_REFS-1) of std_logic_vector(64 downto 0);
  signal table     : table_t;
  signal tbl_raddr : unsigned(RB-1 downto 0);
  signal tbl_rdata : std_logic_vector(64 downto 0);
  signal tbl_q     : std_logic_vector(64 downto 0);   -- BRAM output register
  signal tbl_we    : std_logic := '0';
  signal tbl_waddr : unsigned(RB-1 downto 0) := (others => '0');
  signal tbl_wdata : std_logic_vector(64 downto 0) := (others => '0');

  ---------------------------------------------------------------------------
  -- Control and book state
  ---------------------------------------------------------------------------
  type state_t is (S_IDLE, S_READ, S_DECIDE, S_FIND, S_APPLY);
  signal state : state_t := S_IDLE;

  signal live : std_logic_vector(0 to N_REFS-1) := (others => '0');
  signal bids : book_side_t := EMPTY_SIDE;
  signal asks : book_side_t := EMPTY_SIDE;

  -- Message being processed (latched in S_IDLE)
  signal m_type       : std_logic_vector(7 downto 0) := (others => '0');
  signal m_ref        : unsigned(RB-1 downto 0) := (others => '0');
  signal m_new_ref    : unsigned(RB-1 downto 0) := (others => '0');
  signal m_new_ref_ok : std_logic := '0';        -- new_ref < 2**ORDER_REF_BITS
  signal m_shares     : unsigned(31 downto 0) := (others => '0');
  signal m_price      : unsigned(31 downto 0) := (others => '0');

  -- The level operation in flight
  signal op_kind  : op_t := OP_NONE;
  signal op_side  : std_logic := '0';            -- '0' = bids, '1' = asks
  signal op_price : unsigned(31 downto 0) := (others => '0');
  signal op_qty   : unsigned(31 downto 0) := (others => '0');
  signal u_first  : std_logic := '0';            -- current SUB is the first half of a U
  signal u_second : std_logic := '0';            -- current ADD is the second half of a U
  signal publish  : std_logic := '0';            -- S_APPLY must pulse bbo_valid

  -- Results of S_FIND, used by S_APPLY
  signal f_match : lvl_vec_t := (others => '0');
  signal f_better: lvl_vec_t := (others => '0');
  signal f_geq   : lvl_vec_t := (others => '0');
  signal f_found : boolean := false;
  signal f_rm    : boolean := false;
  signal f_newq  : unsigned(31 downto 0) := (others => '0');

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
  -- Order table: synchronous read + output register (2 cycles), one write port.
  -- The read address is always the incoming ref: the entry of a new message is
  -- in tbl_q two cycles after in_valid (state S_DECIDE).
  ---------------------------------------------------------------------------
  tbl_raddr <= unsigned(in_ref(RB-1 downto 0));

  table_proc : process (clk)
  begin
    if rising_edge(clk) then
      if tbl_we = '1' then
        table(to_integer(tbl_waddr)) <= tbl_wdata;
      end if;
      tbl_rdata <= table(to_integer(tbl_raddr));
      tbl_q     <= tbl_rdata;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Message processing
  ---------------------------------------------------------------------------
  main_proc : process (clk)
    variable ref_i    : natural range 0 to N_REFS-1;
    variable new_i    : natural range 0 to N_REFS-1;
    variable o_side   : std_logic;               -- stored order, from the table
    variable o_price  : unsigned(31 downto 0);
    variable o_shares : unsigned(31 downto 0);
    variable diff     : unsigned(31 downto 0);
    -- S_FIND
    variable sel      : book_side_t;
    variable mv       : lvl_vec_t;
    variable qm       : unsigned(31 downto 0);
    variable full     : boolean;
    -- S_APPLY
    variable bids_v   : book_side_t;
    variable asks_v   : book_side_t;
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
        op_kind     <= OP_NONE;
        u_first     <= '0';
        u_second    <= '0';
        publish     <= '0';
        bid_valid_r <= '0';
        bid_price_r <= (others => '0');
        bid_qty_r   <= (others => '0');
        ask_valid_r <= '0';
        ask_price_r <= (others => '0');
        ask_qty_r   <= (others => '0');

      else
        case state is

          ---------------------------------------------------------------------
          -- Wait for a message; checks that need no table.
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
              u_first  <= '0';
              u_second <= '0';

              ref_i := to_integer(unsigned(in_ref(RB-1 downto 0)));

              if unsigned(in_locate) /= LOCATE then
                null;                                         -- other instrument: ignore silently
              elsif unsigned(in_ref(63 downto RB)) /= 0 then
                err_r <= '1';                                 -- ref out of range
              elsif in_type = MSG_ADD then
                if live(ref_i) = '1' then
                  err_r <= '1';                               -- ref already live
                else
                  op_kind  <= OP_ADD;
                  op_side  <= in_side;
                  op_price <= unsigned(in_price);
                  op_qty   <= unsigned(in_shares);
                  state    <= S_FIND;
                end if;
              elsif in_type = MSG_EXECUTED or in_type = MSG_CANCEL or
                    in_type = MSG_DELETE or in_type = MSG_REPLACE then
                state <= S_READ;
              end if;
            end if;

          ---------------------------------------------------------------------
          when S_READ =>
            state <= S_DECIDE;                              -- BRAM output register

          ---------------------------------------------------------------------
          -- The stored order of m_ref is in tbl_q.
          ---------------------------------------------------------------------
          when S_DECIDE =>
            state    <= S_IDLE;
            ref_i    := to_integer(m_ref);
            new_i    := to_integer(m_new_ref);
            o_side   := tbl_q(64);
            o_price  := unsigned(tbl_q(63 downto 32));
            o_shares := unsigned(tbl_q(31 downto 0));

            if live(ref_i) = '0' then
              err_r <= '1';                                   -- unknown order

            elsif m_type = MSG_EXECUTED or m_type = MSG_CANCEL then
              diff := o_shares - m_shares;
              op_kind  <= OP_SUB;
              op_side  <= o_side;
              op_price <= o_price;
              state    <= S_FIND;
              if m_shares >= o_shares then                    -- order fully gone
                live(ref_i) <= '0';
                op_qty      <= o_shares;                      -- saturate (SPEC 5.4)
                if m_shares > o_shares then
                  err_r <= '1';                               -- overfill
                end if;
              else
                op_qty    <= m_shares;
                tbl_we    <= '1';                             -- store remaining shares
                tbl_waddr <= m_ref;
                tbl_wdata <= o_side & std_logic_vector(o_price) & std_logic_vector(diff);
              end if;

            elsif m_type = MSG_DELETE then
              live(ref_i) <= '0';
              op_kind  <= OP_SUB;
              op_side  <= o_side;
              op_price <= o_price;
              op_qty   <= o_shares;
              state    <= S_FIND;

            elsif m_type = MSG_REPLACE then
              if m_new_ref_ok = '0' or (m_new_ref /= m_ref and live(new_i) = '1') then
                err_r <= '1';                                 -- invalid new ref: book unchanged
              else
                live(ref_i) <= '0';                           -- remove the original order
                op_kind  <= OP_SUB;
                op_side  <= o_side;                           -- new order inherits this side
                op_price <= o_price;
                op_qty   <= o_shares;
                u_first  <= '1';
                state    <= S_FIND;
              end if;
            end if;

          ---------------------------------------------------------------------
          -- Compare the operation's price with every level of its side.
          ---------------------------------------------------------------------
          when S_FIND =>
            state <= S_APPLY;

            if op_side = '0' then
              sel := bids;
            else
              sel := asks;
            end if;
            mv   := match_vec(sel, op_price);
            qm   := match_qty(sel, mv);
            full := sel.count = MAX_LEVELS and not any(mv);

            f_match  <= mv;
            f_better <= better_vec(sel, op_side = '0', op_price);
            f_geq    <= prefix_or(mv);
            f_found  <= any(mv);
            if op_kind = OP_ADD then
              f_newq <= qm + op_qty;
              f_rm   <= false;
            else
              f_newq <= qm - op_qty;
              f_rm   <= not (qm > op_qty);
            end if;

            publish <= not u_first;                         -- first half of a U: no output

            if op_kind = OP_ADD then
              if full then
                err_r <= '1';                                 -- no room for a new level
                if u_second = '1' then
                  op_kind <= OP_NONE;                         -- U: original stays removed,
                  publish <= '1';                             -- still publish the book
                else
                  state <= S_IDLE;                            -- A: rejected, no output
                end if;
              elsif u_second = '1' then
                live(to_integer(m_new_ref)) <= '1';
                tbl_we    <= '1';
                tbl_waddr <= m_new_ref;
                tbl_wdata <= op_side & std_logic_vector(op_price) & std_logic_vector(op_qty);
              else
                live(to_integer(m_ref)) <= '1';
                tbl_we    <= '1';
                tbl_waddr <= m_ref;
                tbl_wdata <= op_side & std_logic_vector(op_price) & std_logic_vector(op_qty);
              end if;
            end if;

          ---------------------------------------------------------------------
          -- Update the levels and publish the top of book.
          ---------------------------------------------------------------------
          when S_APPLY =>
            bids_v := bids;
            asks_v := asks;
            if op_side = '0' then
              bids_v := level_apply(bids, op_kind, f_found, f_rm, f_match, f_better, f_geq,
                                    op_price, op_qty, f_newq);
            else
              asks_v := level_apply(asks, op_kind, f_found, f_rm, f_match, f_better, f_geq,
                                    op_price, op_qty, f_newq);
            end if;
            bids <= bids_v;
            asks <= asks_v;

            if publish = '1' then
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

            if u_first = '1' then
              -- Old order removed; now insert the new one (same side, new price/qty).
              u_first  <= '0';
              u_second <= '1';
              op_kind  <= OP_ADD;
              op_price <= m_price;
              op_qty   <= m_shares;
              state    <= S_FIND;
            else
              state <= S_IDLE;
            end if;

        end case;
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
