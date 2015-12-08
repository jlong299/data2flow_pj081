---------------------------------
-- Author	: JiangLong
-- Date   	: 201511
-- Project	: 081
-- Function	: GE 8bit data --> flow (under specific duty cycle)
-- Description	: Ouput 1 bit data is under duty cycle of ena_glb_1bit
--                Step1 :Input is 8bit data and wren,  1st fifo output is 8bit data like : frmHead + Length + Payload (length=248 or <248)
--                Step2 : Padding
--                step3 : 8bit --> 1bit
--
-- Ports	: rdclk is 1/8 of rdclk_1bit
--            duty cycle of ena_glb and ena_glb_1bit are the same
--            Output 1bit data : frameHead + length + payload + padding .   framHead : B2   length : 1~248    payload(1~248 bytes)   padding : 47
--
-- Problems	: 
-- History	: 
--
----------------------------------
library ieee ;
use ieee.std_logic_1164.all ;
use ieee.numeric_std.all ;

entity data2flow_pj081 is
  port (
  	aReset	: in std_logic;
  	wrclk		: in std_logic;
  	d_in	: in std_logic_vector(7 downto 0) ;
  	wren	: in std_logic;
  	rdclk	: in std_logic;
  	ena_glb	: in std_logic;
  	rdclk_1bit : in std_logic;
  	ena_glb_1bit : in std_logic;

  	d_out	: out std_logic;
  	val_out	: out std_logic
	
  ) ;
end entity ; 

architecture arch of data2flow_pj081 is
component ff_tx_pj081 IS
	PORT
	(
		aclr		: IN STD_LOGIC  := '0';
		data		: IN STD_LOGIC_VECTOR (7 DOWNTO 0);
		rdclk		: IN STD_LOGIC ;
		rdreq		: IN STD_LOGIC ;
		wrclk		: IN STD_LOGIC ;
		wrreq		: IN STD_LOGIC ;
		q		: OUT STD_LOGIC_VECTOR (7 DOWNTO 0);
		rdempty		: OUT STD_LOGIC ;
		rdusedw		: OUT STD_LOGIC_VECTOR (15 DOWNTO 0);
		wrfull		: OUT STD_LOGIC ;
		wrusedw		: OUT STD_LOGIC_VECTOR (15 DOWNTO 0)
	);
END component;

component ff_8to1_pj081 IS
	PORT
	(
		aclr		: IN STD_LOGIC  := '0';
		data		: IN STD_LOGIC_VECTOR (7 DOWNTO 0);
		rdclk		: IN STD_LOGIC ;
		rdreq		: IN STD_LOGIC ;
		wrclk		: IN STD_LOGIC ;
		wrreq		: IN STD_LOGIC ;
		q		: OUT STD_LOGIC_VECTOR (0 DOWNTO 0);
		rdempty		: OUT STD_LOGIC ;
		rdusedw		: OUT STD_LOGIC_VECTOR (16 DOWNTO 0);
		wrfull		: OUT STD_LOGIC 
	);
END component;


 component PN_ERR_Detect IS
		 PORT
		(
			 aReset	:		IN std_logic;
		   ClockIn:  	IN  STD_LOGIC;
		   Enable	: 	In	std_logic; --����ʹ���ź�
		   DataIn	:  	IN  STD_LOGIC; -- ��ͳ������
		   SyncFlag:  Out  STD_LOGIC;--�������з�����ͬ��ָʾ
		   ErrResult: Out  STD_LOGIC_VECTOR(31 DOWNTO 0) --�����������
		);
 END component;

	-- Build an enumerated type for the state machine
	--type state_type is (s0, s1);

	-- Register to hold the current state
	signal state   : std_logic;
	constant s0 : std_logic := '0';
	constant s1 : std_logic := '1';

signal 	aclr		:  STD_LOGIC  := '0';
signal 	d_in_reg		:  STD_LOGIC_VECTOR (7 DOWNTO 0);
signal 	rdreq		:  STD_LOGIC ;
signal 	wren_reg		:  STD_LOGIC ;
signal 	q		:  STD_LOGIC_VECTOR (7 DOWNTO 0);
signal 	rdempty		:  STD_LOGIC ;
signal 	rdusedw	, wrusedw	:  STD_LOGIC_VECTOR (15 DOWNTO 0);
signal 	wrfull		:  STD_LOGIC;

--signal cnt_s0 : integer range 0 to 7;
signal len_record, cnt_rden : unsigned(15 downto 0);
constant cnst_len : unsigned(15 downto 0) := to_unsigned(2048,16);--2048,16);

signal d_ff_out : std_logic_vector(7 downto 0) ;
signal val_ff_out, rden, s1_finish : std_logic;

signal d_padding : std_logic_vector(7 downto 0) ;
signal rdreq_1bit, rdempty_1bit, rdreq_start : std_logic;
signal rdusedw_1bit : std_logic_vector(16 downto 0) ;

begin


--------------------------------------------
----------- PART 1 : fifo declaration ------
--------------------------------------------
ff_tx_pj081_inst : ff_tx_pj081
PORT map
	(
		aclr		=> aReset ,
		data		=> d_in_reg ,
		rdclk		=> rdclk ,
		rdreq		=> rdreq ,
		wrclk		=> wrclk ,
		wrreq		=> wren_reg ,
		q			=> q ,
		rdempty		=> rdempty ,
		rdusedw		=> rdusedw ,
		wrfull		=> wrfull ,
		wrusedw		=> wrusedw
	);

-------------------------------------------
---------- PART 2 : Wrtie FIFO
--------------------------------------------
-- 
process( wrclk, aReset )
begin
  if( aReset = '1' ) then
    d_in_reg <= (others => '0');
  elsif( rising_edge(wrclk) ) then
  	d_in_reg <= d_in;
  end if ;
end process ; 

 -- avoid fifo full
process( wrclk, wrfull )
begin
  if( wrfull = '1' ) then
    wren_reg <= '0';
  elsif( rising_edge(wrclk) ) then
  	if wrusedw(wrusedw'high downto wrusedw'high-7) = "11111111" then
  		wren_reg <= '0';
  	else
	  	wren_reg <= wren;
	end if;
  end if ;
end process ; 

--------------------------------------------
----------  PART 3 : READ FIFO
--------------------------------------------
----------  state machine ----------------
	-- Logic to advance to the next state
	process (rdclk, aReset)
	begin
		if aReset = '1' then	
			state <= s0;
			len_record <= (others => '0');
		elsif (rising_edge(rdclk)) then
		if ena_glb = '1' then
			case state is
				when s0=>
					if rdempty = '1' or (rdusedw = (rdusedw'range => '0')) then
						state <= s0;
					-- (rdusedw = (rdusedw'range => '0')  -->  full
					elsif ( unsigned(rdusedw) >= resize(cnst_len,rdusedw'length))  then
						state <= s1;
						len_record <= cnst_len;
					else
						state <= s1;
						len_record <= resize(unsigned(rdusedw),len_record'length);
					end if;
				when s1 =>
					if s1_finish = '1' then
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

----------------  End    state machine --------------------------

-- 	rden		
process( rdclk, aReset )
begin
  if( aReset = '1' ) then
    rden <= '0' ;
    cnt_rden <= (others => '0');
    s1_finish <= '0' ;
  elsif( rising_edge(rdclk) ) then
  if ena_glb = '1'  then
  	if state = s1 then
  		if cnt_rden = (len_record+6) then
  			cnt_rden <= (others => '0');
  		else
  			cnt_rden <= cnt_rden + 1;
  		end if;

  		if cnt_rden = (len_record+4) then
  			s1_finish <= '1';
  		else
  			s1_finish <= '0';
  		end if;

--  		if cnt_rden = 2 then
--  			rden <= '1' ;
--  		elsif cnt_rden = (len_record+2) then
--  			rden <= '0' ;
--  		else
--  			rden <= rden;
--  		end if;

		if (cnt_rden >= 4) and (cnt_rden < (len_record+4) )then
  			rden <= '1' ;
  		else
  			rden <= '0';
  		end if;
			
  	else
  		cnt_rden <= (others => '0');
  		rden <= '0' ;
  		s1_finish <= '0' ;
  	end if;
  else
  	--rden <= '0';
  	cnt_rden <= cnt_rden;
  end if;
  end if ;
end process ; 

-----------------------------------------------
-- ena_glb :  1  1  0  0  0  0  1  1  
-- rden    :  0  0  1  1  1  1  1  0
-- rdreq   :  0  0  0  0  0  0  1  0
-- rdreq should not be '1' when ena_glb='0'
-----------------------------------------------
process(rden, ena_glb)
begin
	rdreq <= rden and ena_glb;
end process;


-- val_ff_out , d_ff_out
process( rdclk, aReset )
begin
  if( aReset = '1' ) then
    val_ff_out <= '0';
    d_ff_out <= (others => '0');
  elsif( rising_edge(rdclk) ) then
  if ena_glb = '1'  then
  	if state = s1 then
  		--if cnt_rden = 2 then
		if cnt_rden = 0 then
  			val_ff_out <= '1' ;
  		elsif cnt_rden = (len_record+6) then
  			val_ff_out <= '0';
  		else
  			val_ff_out <= val_ff_out;
  		end if;

  		case cnt_rden is
  		when to_unsigned(0,16) =>
  			d_ff_out <= x"1A";  -- Head 
  		when to_unsigned(1,16) =>
  			d_ff_out <= x"CF";  -- Head 
  		when to_unsigned(2,16) =>
  			d_ff_out <= x"FC";  -- Head 
  		when to_unsigned(3,16) =>
  			d_ff_out <= x"ED";  -- Head
  		when to_unsigned(4,16) =>
  			d_ff_out <= std_logic_vector(len_record(15 downto 8)); -- Len
  		when to_unsigned(5,16) =>
  			d_ff_out <= std_logic_vector(len_record(7 downto 0)); -- Len
  		when others =>
  			d_ff_out <= q;
  		end case;

  	else
  		val_ff_out <= '0';
  		d_ff_out <= (others => '0');
  	end if;
  end if;
  end if ;
end process ; 



------------------------------------------
-----------  PART 4  : Padding  ----------
------------------------------------------
-- padding
process( rdclk, aReset )
begin
  if( aReset = '1' ) then
    d_padding <= (others => '0');			
  elsif( rising_edge(rdclk) ) then
  if ena_glb = '1'  then
  	if val_ff_out = '1' then
  		d_padding <= d_ff_out;
  	else
  		d_padding <= "01000111"; -- Padding 47
  	end if;
  end if;
  end if ;
end process ; 

----------------------------------------------
----------  PART 5 :  8 to 1
----------------------------------------------

	-- 8bits to 1bit
	ff_8to1_pj081_inst:  ff_8to1_pj081
	PORT map
	(
		aclr		=> aReset,
		data		=> d_padding,
		rdclk		=> rdclk_1bit,
		rdreq		=> rdreq_1bit,
		wrclk		=> rdclk,
		wrreq		=> ena_glb,
		q(0)		   => d_out,
		rdempty	=> rdempty_1bit,
		rdusedw	=> rdusedw_1bit,		
		wrfull	=> open
		
	);

    -- ena_glb and ean_glb_1bit must start and the same time after reset !!
	process( aReset, rdclk_1bit)
	begin
		if aReset='1' then
			rdreq_1bit <= '0';
			rdreq_start <= '0';
			val_out <= '0';
		elsif rising_edge(rdclk_1bit) then	
		if ena_glb_1bit='1' then
			if rdempty_1bit = '1' then
				rdreq_1bit <= '0';
				rdreq_start <= '0';
			elsif  rdreq_start='0' then
				if (unsigned(rdusedw_1bit) > to_unsigned( 1024, rdusedw_1bit'length)) then
					rdreq_start <= '1';
					rdreq_1bit <= '0';
				else
					rdreq_start <= '0';
					rdreq_1bit <= '0';
				end if;
			else
				rdreq_1bit <= '1';
				rdreq_start <= rdreq_start;
			end if;
		
		else
			rdreq_1bit <= '0';
		end if;
			
			val_out <= ena_glb_1bit;
		end if;
	end process;





end architecture ;