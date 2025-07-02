--
-- VHDL Entity for an APB Bus Driver and CPU Master Simulation Model
--
-- This entity models a simple CPU master that drives an APB bus. It reads a
-- command file to execute a sequence of operations like write, read, branch,
-- and goto. This is intended for simulation purposes to verify APB slave
-- devices.
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity apb_bus_driver is
    generic (
        -- Path to the command file
        G_COMMAND_FILE      : string  := "commands.txt";
        -- APB Address Bus Width
        G_APB_ADDR_WIDTH    : integer := 32;
        -- APB Data Bus Width
        G_APB_DATA_WIDTH    : integer := 32
    );
    port (
        -- Clock and Reset
        pclk                : in  std_logic;
        presetn             : in  std_logic;

        -- APB Interface
        paddr               : out std_logic_vector(G_APB_ADDR_WIDTH - 1 downto 0);
        pprot               : out std_logic_vector(2 downto 0);
        psel                : out std_logic;
        penable             : out std_logic;
        pwrite              : out std_logic;
        pwdata              : out std_logic_vector(G_APB_DATA_WIDTH - 1 downto 0);
        pready              : in  std_logic;
        prdata              : in  std_logic_vector(G_APB_DATA_WIDTH - 1 downto 0);
        pslverr             : in  std_logic
    );
end entity apb_bus_driver;

architecture rtl of apb_bus_driver is

    -- APB state machine
    type t_apb_state is (IDLE, SETUP, ACCESS);
    signal apb_state        : t_apb_state := IDLE;

    -- Internal signals for APB driving
    signal s_paddr          : std_logic_vector(G_APB_ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal s_pwrite         : std_logic := '0';
    signal s_psel           : std_logic := '0';
    signal s_penable        : std_logic := '0';
    signal s_pwdata         : std_logic_vector(G_APB_DATA_WIDTH - 1 downto 0) := (others => '0');

    -- Command file processing signals
    type t_command_memory is array (0 to 255) of line;
    shared variable v_command_memory : t_command_memory;
    signal s_program_counter: integer range 0 to 255 := 0;
    signal s_command_line   : line;
    signal s_end_of_file    : boolean := false;

    -- Decoded command fields
    signal s_line_number    : integer;
    signal s_opcode         : string(1 to 5);
    signal s_address        : std_logic_vector(G_APB_ADDR_WIDTH - 1 downto 0);
    signal s_data           : std_logic_vector(G_APB_DATA_WIDTH - 1 downto 0);


begin

    -- Drive output ports from internal signals
    paddr   <= s_paddr;
    pprot   <= "000"; -- Default protection type
    psel    <= s_psel;
    penable <= s_penable;
    pwrite  <= s_pwrite;
    pwdata  <= s_pwdata;

    -- This process reads the command file into a memory-like structure.
    -- This allows for goto and branch operations by manipulating a program counter.
    file_reader_proc: process
        file command_file   : text;
        variable file_line  : line;
        variable line_index : integer := 0;
    begin
        file_open(command_file, G_COMMAND_FILE, read_mode);
        while not endfile(command_file) and line_index < v_command_memory'length loop
            readline(command_file, file_line);
            v_command_memory(line_index) := file_line;
            line_index := line_index + 1;
        end loop;
        file_close(command_file);
        wait;
    end process file_reader_proc;

    -- This is the main process that fetches, decodes, and executes commands.
    command_processor_proc: process
        variable v_line_num_val : integer;
        variable v_opcode_val   : string(1 to 5);
        variable v_addr_val     : std_logic_vector(G_APB_ADDR_WIDTH - 1 downto 0);
        variable v_data_val     : std_logic_vector(G_APB_DATA_WIDTH - 1 downto 0);
        variable v_branch_taken : boolean := false;

        procedure parse_line (
            l           : in    line;
            line_num    : out   integer;
            opcode      : out   string(1 to 5);
            address     : out   std_logic_vector(G_APB_ADDR_WIDTH - 1 downto 0);
            data        : out   std_logic_vector(G_APB_DATA_WIDTH - 1 downto 0)
        ) is
            variable temp_line_num : integer;
            variable temp_opcode   : string(1 to 5);
            variable temp_addr     : bit_vector(G_APB_ADDR_WIDTH - 1 downto 0);
            variable temp_data     : bit_vector(G_APB_DATA_WIDTH - 1 downto 0);
            variable space         : character;
        begin
            read(l, temp_line_num);
            read(l, space);
            read(l, temp_opcode);
            read(l, space);
            hread(l, temp_addr);
            read(l, space);
            hread(l, temp_data);

            line_num    := temp_line_num;
            opcode      := temp_opcode;
            address     := to_stdlogicvector(temp_addr);
            data        := to_stdlogicvector(temp_data);
        end procedure;

    begin
        wait until rising_edge(pclk);
        if presetn = '0' then
            s_program_counter <= 0;
            s_end_of_file     <= false;
            apb_state         <= IDLE;
            s_psel            <= '0';
            s_penable         <= '0';
        else
            if not s_end_of_file then
                if apb_state = IDLE then
                    s_command_line <= v_command_memory(s_program_counter);
                    if s_command_line = null then
                        s_end_of_file <= true;
                    else
                        parse_line(s_command_line, v_line_num_val, v_opcode_val, v_addr_val, v_data_val);

                        s_line_number <= v_line_num_val;
                        s_opcode      <= v_opcode_val;
                        s_address     <= v_addr_val;
                        s_data        <= v_data_val;

                        case v_opcode_val is
                            when "write" =>
                                s_paddr   <= v_addr_val;
                                s_pwdata  <= v_data_val;
                                s_pwrite  <= '1';
                                apb_state <= SETUP;
                                s_psel    <= '1';
                                s_program_counter <= s_program_counter + 1;
                            when "read " =>
                                s_paddr   <= v_addr_val;
                                s_pwrite  <= '0';
                                apb_state <= SETUP;
                                s_psel    <= '1';
                                s_program_counter <= s_program_counter + 1;
                            when "bran " =>
                                if prdata = v_data_val then
                                    s_program_counter <= to_integer(unsigned(v_addr_val(7 downto 0)));
                                else
                                    s_program_counter <= s_program_counter + 1;
                                end if;
                            when "goto " =>
                                s_program_counter <= to_integer(unsigned(v_addr_val(7 downto 0)));
                            when others =>
                                s_program_counter <= s_program_counter + 1;
                        end case;
                    end if;
                elsif apb_state = SETUP then
                    s_penable <= '1';
                    apb_state <= ACCESS;
                elsif apb_state = ACCESS then
                    if pready = '1' then
                        s_psel    <= '0';
                        s_penable <= '0';
                        apb_state <= IDLE;
                    end if;
                end if;
            end if;
        end if;
    end process command_processor_proc;

end architecture rtl;