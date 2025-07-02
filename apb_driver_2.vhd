--
-- VHDL Entity for an APB Bus Driver and CPU Master Simulation Model
--
-- This version uses labels for control flow (goto/branch) instead of line numbers.
-- It performs a two-pass scan of the command file:
-- 1. First Pass: Build a symbol table of all labels and their line indices.
-- 2. Second Pass: Execute the commands, using the symbol table to resolve jumps.
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all; -- For hread/hwrite

entity apb_bus_driver is
    generic (
        -- Path to the command file
        G_COMMAND_FILE      : string  := "commands.txt";
        -- APB Address Bus Width
        G_APB_ADDR_WIDTH    : integer := 32;
        -- APB Data Bus Width
        G_APB_DATA_WIDTH    : integer := 32;
        -- Max number of lines in the command file
        G_MAX_LINES         : integer := 256;
        -- Max number of labels in the command file
        G_MAX_LABELS        : integer := 64;
        -- Max length of a label string
        G_MAX_LABEL_LENGTH  : integer := 16
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
    type t_apb_state is (IDLE, SETUP, ACCESS, HALTED);
    signal apb_state        : t_apb_state := IDLE;

    -- Internal signals for APB driving
    signal s_paddr          : std_logic_vector(G_APB_ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal s_pwrite         : std_logic := '0';
    signal s_psel           : std_logic := '0';
    signal s_penable        : std_logic := '0';
    signal s_pwdata         : std_logic_vector(G_APB_DATA_WIDTH - 1 downto 0) := (others => '0');

    -- Command file and label processing signals
    -- Type for storing the command file in memory
    type t_command_memory is array (0 to G_MAX_LINES - 1) of string(1 to 256);
    shared variable v_command_memory : t_command_memory;
    shared variable v_line_count : integer := 0;

    -- Type for the symbol table (labels)
    type t_label_record is record
        name    : string(1 to G_MAX_LABEL_LENGTH);
        line_idx: integer;
    end record;
    type t_symbol_table is array (0 to G_MAX_LABELS - 1) of t_label_record;
    shared variable v_symbol_table : t_symbol_table;
    shared variable v_label_count : integer := 0;

    signal s_program_counter: integer range 0 to G_MAX_LINES := 0;

    -- Helper function to compare strings
    function strcmp (s1, s2: string) return boolean is
    begin
        return s1(s1'range) = s2(s2'range);
    end function;

begin

    -- Drive output ports from internal signals
    paddr   <= s_paddr;
    pprot   <= "000"; -- Default protection type
    psel    <= s_psel;
    penable <= s_penable;
    pwrite  <= s_pwrite;
    pwdata  <= s_pwdata;

    -- **PASS 1: Read file and build symbol table**
    -- This process runs once at the start of the simulation to populate
    -- the command memory and the label symbol table.
    file_reader_proc: process
        file command_file   : text;
        variable file_line  : line;
        variable line_buf   : string(1 to 256);
        variable line_len   : integer;
        variable current_char : character;
        variable is_label   : boolean;
        variable label_str  : string(1 to G_MAX_LABEL_LENGTH);
    begin
        -- Initialize shared variables
        v_line_count := 0;
        v_label_count := 0;
        for i in v_symbol_table'range loop
            v_symbol_table(i).name := (others => ' ');
        end loop;

        file_open(command_file, G_COMMAND_FILE, read_mode);

        while not endfile(command_file) and v_line_count < G_MAX_LINES loop
            readline(command_file, file_line);
            -- Read line into a buffer to check for labels
            line_len := 0;
            line_buf := (others => ' ');
            while not end_of_line(file_line) and line_len < line_buf'length loop
                line_len := line_len + 1;
                read(file_line, line_buf(line_len));
            end loop;

            -- Store the raw line (including any label)
            v_command_memory(v_line_count) := line_buf;

            -- Check for a label (contains ':')
            is_label := false;
            for i in 1 to line_len loop
                if line_buf(i) = ':' then
                    is_label := true;
                    -- Extract label string
                    label_str := (others => ' ');
                    label_str(1 to i-1) := line_buf(1 to i-1);
                    -- Store in symbol table
                    if v_label_count < G_MAX_LABELS then
                        v_symbol_table(v_label_count).name := label_str;
                        v_symbol_table(v_label_count).line_idx := v_line_count;
                        v_label_count := v_label_count + 1;
                    end if;
                    exit;
                end if;
            end loop;
            v_line_count := v_line_count + 1;
        end loop;
        file_close(command_file);
        wait;
    end process file_reader_proc;

    -- **PASS 2: Execute Commands**
    -- This is the main process that fetches, decodes, and executes commands.
    command_processor_proc: process
        variable L              : line;
        variable raw_line       : string(1 to 256);
        variable v_opcode       : string(1 to 5);
        variable v_addr_val     : std_logic_vector(G_APB_ADDR_WIDTH - 1 downto 0);
        variable v_data_val     : std_logic_vector(G_APB_DATA_WIDTH - 1 downto 0);
        variable v_label_target : string(1 to G_MAX_LABEL_LENGTH);
        variable next_pc        : integer;

        -- Looks up a label in the symbol table and returns its line index
        function find_label_pc(label_name : string) return integer is
        begin
            for i in 0 to v_label_count - 1 loop
                if strcmp(v_symbol_table(i).name, label_name) then
                    return v_symbol_table(i).line_idx;
                end if;
            end loop;
            return -1; -- Not found
        end function;

        -- Parses a line, skipping over an initial label if present
        procedure parse_line (
            l           : inout line;
            opcode      : out   string(1 to 5);
            p1_is_label : out   boolean;
            param1      : out   string(1 to G_MAX_LABEL_LENGTH);
            param1_slv  : out   std_logic_vector(G_APB_ADDR_WIDTH - 1 downto 0);
            param2      : out   std_logic_vector(G_APB_DATA_WIDTH - 1 downto 0)
        ) is
            variable first_word : string(1 to G_MAX_LABEL_LENGTH);
            variable temp_word  : string(1 to 256);
            variable temp_addr  : bit_vector(G_APB_ADDR_WIDTH - 1 downto 0);
            variable temp_data  : bit_vector(G_APB_DATA_WIDTH - 1 downto 0);
            variable space      : character;
        begin
            -- Reset outputs
            p1_is_label := false;
            opcode      := (others => ' ');
            param1      := (others => ' ');
            param1_slv  := (others => '0');
            param2      := (others => '0');

            -- Check for and skip over a label
            read(l, first_word);
            if first_word(first_word'length) = ':' then
                -- It's a label, so the next word is the opcode
                read(l, space);
                read(l, opcode);
            else
                -- Not a label, so the first word is the opcode
                opcode(1 to first_word'length) := first_word(1 to first_word'length);
            end if;

            -- Parse remaining parameters based on opcode
            if opcode = "write" or opcode = "read " then
                read(l, space);
                hread(l, temp_addr);
                read(l, space);
                hread(l, temp_data);
                param1_slv := to_stdlogicvector(temp_addr);
                param2     := to_stdlogicvector(temp_data);
            elsif opcode = "goto " then
                p1_is_label := true;
                read(l, space);
                read(l, temp_word);
                param1(1 to temp_word'length) := temp_word;
            elsif opcode = "bran " then
                p1_is_label := true;
                read(l, space);
                read(l, temp_word); -- label
                param1(1 to temp_word'length) := temp_word;
                read(l, space);
                hread(l, temp_data); -- data to compare
                param2 := to_stdlogicvector(temp_data);
            end if;

        end procedure;

    begin
        wait until rising_edge(pclk);
        if presetn = '0' then
            s_program_counter <= 0;
            apb_state         <= IDLE;
            s_psel            <= '0';
            s_penable         <= '0';
        else
            if apb_state = HALTED then
                -- Do nothing
            elsif s_program_counter >= v_line_count then
                 report "End of command file reached." severity note;
                 apb_state <= HALTED;
            else
                case apb_state is
                    when IDLE =>
                        next_pc := s_program_counter + 1; -- Default to next line

                        -- Fetch and parse the current line
                        raw_line := v_command_memory(s_program_counter);
                        L := new string'(raw_line);
                        parse_line(L, v_opcode, v_addr_val, v_data_val, v_label_target); -- Simplified call for clarity

                        -- Deallocate the line
                        deallocate(L);

                        -- Decode opcode and act
                        case v_opcode is
                            when "write" =>
                                s_paddr   <= v_addr_val;
                                s_pwdata  <= v_data_val;
                                s_pwrite  <= '1';
                                apb_state <= SETUP;
                                s_psel    <= '1';
                            when "read " =>
                                s_paddr   <= v_addr_val;
                                s_pwrite  <= '0';
                                apb_state <= SETUP;
                                s_psel    <= '1';
                            when "bran " =>
                                if prdata = v_data_val then
                                    next_pc := find_label_pc(v_label_target);
                                    if next_pc = -1 then
                                        report "FATAL: Branch label not found: " & v_label_target severity failure;
                                        apb_state <= HALTED;
                                    end if;
                                end if;
                            when "goto " =>
                                next_pc := find_label_pc(v_label_target);
                                if next_pc = -1 then
                                    report "FATAL: Goto label not found: " & v_label_target severity failure;
                                    apb_state <= HALTED;
                                end if;
                            when others => -- This includes blank lines or lines with only a label
                                null;
                        end case;
                        s_program_counter <= next_pc;

                    when SETUP =>
                        s_penable <= '1';
                        apb_state <= ACCESS;
                    when ACCESS =>
                        if pready = '1' then
                            s_psel    <= '0';
                            s_penable <= '0';
                            apb_state <= IDLE;
                        end if;
                    when others =>
                        apb_state <= IDLE;
                end case;
            end if;
        end if;
    end process command_processor_proc;

end architecture rtl;