---------------------------------
-- Author	: JiangLong
-- Date   	: 201511
-- Project	: pj081
-- Function	: flow --> data
-- Description	: Input :  1bit data  and valid.   data :  frameHead + length + payload + padding
--                 framHead : B2   length : 1~248    payload(1~248 bytes)   padding : 47
--                Output :  8bit data and valid.   data : only payload
-- Ports	: 
--
-- Problems	: 
-- History	: 
--           verson 2  20151201 
--           Input 1bit data : frameHead + length + payload + padding .   framHead : 1ACFFCED(4 bytes)   length : 1~2048(2bytes)    payload(1~2048 bytes)   
--           padding : 47    padding is need only when FIFO is empty
--
--       verson  20151214
--       Payload = payload + scramble code
--       padding : pn23_pd(4) & pn23_pd(4) & pn23_pd(3) & pn23_pd(3) & pn23_pd(2) & pn23_pd(2) & pn23_pd(1) & pn23_pd(1)
--                 pn23_pd is another scramble code
--       frameHead :  5A4B4BA5 (01011010110100101101001010100101), which has only 6 "00" or "11"
----------------------------------
library ieee ;
use ieee.std_logic_1164.all ;
use ieee.numeric_std.all ;

entity flow2data_pj081 is
  port (
  	aReset	: in std_logic;
  	clk_1bit : in std_logic;
  	d_in	 : in std_logic;
  	val_in	 : in std_logic;

  	d_out	 : out std_logic_vector(7 downto 0) ;
  	val_out	 : out std_logic;
    cnt_amount_frms_out : out unsigned(31 downto 0)  --sync to clk_1bit

  ) ;
end entity ; 

architecture arch of flow2data_pj081 is

signal d_reg : std_logic_vector(33 downto 0) ;
	-- Build an enumerated type for the state machine
	--type state_type is (s0, s1, s20, s21);

	-- Register to hold the current state
  signal state   : std_logic;
  constant s0 : std_logic := '0';
  constant s1 : std_logic := '1';

signal length_record : unsigned(15 downto 0);
signal s1_finish, hit_head: std_logic;
signal cnt_s1 : unsigned(2 downto 0);
 signal cnt_s1_len : unsigned(15 downto 0);

 constant cnst_len_max : unsigned(15 downto 0) := to_unsigned(2048,16);--2048,16);
signal pn23 : std_logic_vector(23 downto 1) ;

signal hit_head_d : std_logic;
signal cnt_amount_frms :  unsigned(31 downto 0);

begin

-------------------------------------------------------------
---------------- PART 1 : d_reg
-------------------------------------------------------------

-- identifier
process( clk_1bit, aReset )
begin
  if( aReset = '1' ) then
    d_reg <= (others => '0');     
  elsif( rising_edge(clk_1bit) ) then
  if val_in = '1'  then
    d_reg(33) <= d_in;
    d_reg(32 downto 0) <= d_reg(33 downto 1);
  end if;
  end if ;
end process ; 

-- hit_head
process( clk_1bit, aReset )
begin
  if( aReset = '1' ) then
    hit_head <= '0' ;
  elsif( rising_edge(clk_1bit) ) then
  if val_in = '1'  then
    if d_reg(33 downto 2) = x"D20CCF1A" then --x"EDFCCF1A" then   -- Found Head
      hit_head <= '1' ;
    else
      hit_head <= '0' ;
    end if;
  end if;
  end if ;
end process ; 

--------------------------------------------------------------
---------------  PART 2 : Remove frame head,length 
--------------------------------------------------------------

--------------   State machine  ---------------------

	-- Logic to advance to the next state
	process (clk_1bit, aReset)
	begin
		if aReset = '1' then
			state <= s0;
		elsif (rising_edge(clk_1bit)) then
		if val_in = '1'  then
			case state is
				when s0=>
					if hit_head = '1' then  -- Found Head
						state <= s1;
					else
						state <= s0;
					end if;
				when s1=>
					if s1_finish = '1'  then  -- Frame end
						state <= s0;
					else
						state <= s1;
					end if;
				when others =>
					state <= s0;
			end case;
		end if;
		end if;
	end process;


---------   End  of state machine ---------------------

 -- cnt_s1    0 ~ 7   counter for 1to8 trans
 process( clk_1bit, aReset )
 begin
   if( aReset = '1' ) then
     cnt_s1 <= (others => '0');
   elsif( rising_edge(clk_1bit) ) then
     if val_in = '1'  then
      if state = s1 then
        cnt_s1 <= cnt_s1 + 1;
      else
        cnt_s1 <= (others => '0');
      end if;
    end if;
   end if ;
 end process ; 

 -- cnt_s1_len    counter for frame   
 process( clk_1bit, aReset )
 begin
   if( aReset = '1' ) then
     cnt_s1_len <= (others => '0');
   elsif( rising_edge(clk_1bit) ) then
     if val_in = '1'  then
        if state = s1 then
          if cnt_s1 = "000" then
            cnt_s1_len <= cnt_s1_len + 1;
          end if;
        else
          cnt_s1_len <= (others => '0');
        end if;
    end if;
   end if ;
 end process ; 


 --length_record      get from length field 
 process( clk_1bit, aReset )
 begin
   if( aReset = '1' ) then
     length_record <= (others => '0');
   elsif( rising_edge(clk_1bit) ) then
     if val_in = '1'  then
          if cnt_s1 = "000" then
            if cnt_s1_len = 4 then
              length_record(15 downto 8) <= unsigned(d_reg(7 downto 0));
            end if;

            if cnt_s1_len = 5 then
              length_record(7 downto 0) <= unsigned(d_reg(7 downto 0));
            end if;
          end if;
      end if;
   end if ;
 end process ; 

 -- d_out val_out s1_finish
 process( clk_1bit, aReset )
 begin
   if( aReset = '1' ) then
     d_out <= (others => '0');
     val_out <= '0' ;
     s1_finish <= '0' ;
     pn23 <= (others => '0');
   elsif( rising_edge(clk_1bit) ) then
     if val_in = '1'  then
        if cnt_s1 = "000" then
            ------------  de-scramble ---------------
              if cnt_s1_len <= 5 then
                    pn23(23 downto 21) <= (others => '0');
                    pn23(20 downto 1) <= x"3725f";
              else 
                    pn23(23 downto 9) <= pn23(15 downto 1);
                    pn23(8 downto 1)  <= pn23(23 downto 16) xor pn23(18 downto 11);
              end if;
              ---------------------------------------------------
            if cnt_s1_len >= 6 then
              d_out <= d_reg(7 downto 0) xor pn23(23 downto 16);
            end if;

            if (cnt_s1_len >= 6) then --and (cnt_s1_len < (length_record+6)) then
              val_out <= '1' ;
            else
              val_out <= '0' ;
            end if;

            if (cnt_s1_len > 5) and ( cnt_s1_len = (length_record+5)) then   -- must > 5 (min len)
              s1_finish <= '1';
            elsif cnt_s1_len = ( cnst_len_max + 16 ) then   -- (max len plus)
					s1_finish <= '1';
				else
              s1_finish <= '0';
            end if;
        else
            val_out <= '0' ;
            s1_finish <= '0';
        end if;
		else
			val_out <= '0';
      end if;
   end if ;
 end process ; 

-- cnt amount of frames
-- 
process( clk_1bit, aReset )
begin
  if( aReset = '1' ) then
    hit_head_d <= '0' ;
    cnt_amount_frms <= (others => '0');
  elsif( rising_edge(clk_1bit) ) then
    hit_head_d <= hit_head;
    if hit_head = '1' and hit_head_d = '0' then
      cnt_amount_frms <= cnt_amount_frms + 1;
    end if;
  end if ;
end process ; 
cnt_amount_frms_out <= cnt_amount_frms;


end architecture ;
