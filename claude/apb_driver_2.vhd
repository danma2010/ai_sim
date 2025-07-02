library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity apb_bus_driver is
    generic (
        ADDR_WIDTH : integer := 32;
        DATA_WIDTH : integer := 32;
        TEST_FILE  : string := "test_commands.txt"
    );
    port (
        -- Clock and Reset
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        
        -- APB Master Interface
        paddr     : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        psel      : out std_logic;
        penable   : out std_logic;
        pwrite    : out std_logic;
        pwdata    : out std_logic_vector(DATA_WIDTH-1 downto 0);
        pready    : in  std_logic;
        prdata    : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        pslverr   : in  std_logic;
        
        -- Control Signals
        start     : in  std_logic;
        done      : out std_logic;
        error     : out std_logic
    );
end entity apb_bus_driver;

architecture behavioral of apb_bus_driver is
    
    -- Command Types
    type cmd_type is (CMD_WRITE, CMD_READ, CMD_BRANCH, CMD_GOTO, CMD_LABEL, CMD_INVALID);
    
    -- Command Record
    type command_rec is record
        cmd   : cmd_type;
        addr  : std_logic_vector(ADDR_WIDTH-1 downto 0);
        data  : std_logic_vector(DATA_WIDTH-1 downto 0);
        label : string(1 to 32);
        label_len : integer;
    end record;
    
    -- Command Memory (assuming max 1024 commands)
    type cmd_memory_type is array (0 to 1023) of command_rec;
    signal cmd_memory : cmd_memory_type;
    
    -- Label Table (for goto/branch resolution)
    type label_entry is record
        name    : string(1 to 32);
        name_len: integer;
        addr    : integer;
        valid   : boolean;
    end record;
    
    type label_table_type is array (0 to 255) of label_entry;
    signal label_table : label_table_type;
    
    -- State Machine
    type state_type is (IDLE, LOAD_FILE, PARSE_LABELS, EXECUTE, APB_SETUP, APB_ACCESS, APB_WAIT, BRANCH_EVAL, COMPLETE, ERROR_STATE);
    signal state : state_type := IDLE;
    
    -- Internal Signals
    signal pc : integer := 0;  -- Program Counter
    signal cmd_count : integer := 0;
    signal label_count : integer := 0;
    signal file_loaded : boolean := false;
    signal current_cmd : command_rec;
    signal branch_condition : std_logic := '0';
    signal last_read_data : std_logic_vector(DATA_WIDTH-1 downto 0);
    
    -- APB State Machine
    type apb_state_type is (APB_IDLE, APB_SETUP_STATE, APB_ACCESS_STATE);
    signal apb_state : apb_state_type := APB_IDLE;
    
    -- Function to convert string to command type
    function str_to_cmd(s : string) return cmd_type is
    begin
        if s = "WRITE" or s = "write" then
            return CMD_WRITE;
        elsif s = "READ" or s = "read" then
            return CMD_READ;
        elsif s = "BRANCH" or s = "branch" then
            return CMD_BRANCH;
        elsif s = "GOTO" or s = "goto" then
            return CMD_GOTO;
        else
            return CMD_INVALID;
        end if;
    end function;
    
    -- Function to find label address
    function find_label(name : string; len : integer) return integer is
    begin
        for i in 0 to label_count-1 loop
            if label_table(i).valid and 
               label_table(i).name_len = len and
               label_table(i).name(1 to len) = name(1 to len) then
                return label_table(i).addr;
            end if;
        end loop;
        return -1; -- Label not found
    end function;
    
    -- Procedure to load test file
    procedure load_test_file is
        file test_file : text;
        variable line_buf : line;
        variable line_str : string(1 to 256);
        variable line_len : integer;
        variable cmd_str : string(1 to 32);
        variable addr_str : string(1 to 32);
        variable data_str : string(1 to 32);
        variable temp_cmd : command_rec;
        variable char : character;
        variable pos : integer;
        variable word_start : integer;
        variable word_end : integer;
        variable word_count : integer;
        variable is_label : boolean;
        variable cmd_idx : integer := 0;
    begin
        file_open(test_file, TEST_FILE, read_mode);
        
        while not endfile(test_file) and cmd_idx < 1024 loop
            readline(test_file, line_buf);
            
            -- Convert line to string
            line_len := line_buf'length;
            if line_len > 256 then
                line_len := 256;
            end if;
            
            read(line_buf, line_str(1 to line_len));
            
            -- Skip empty lines and comments
            if line_len = 0 or line_str(1) = '#' then
                next;
            end if;
            
            -- Initialize command record
            temp_cmd.cmd := CMD_INVALID;
            temp_cmd.addr := (others => '0');
            temp_cmd.data := (others => '0');
            temp_cmd.label := (others => ' ');
            temp_cmd.label_len := 0;
            
            -- Check if line contains a label (ends with ':')
            is_label := false;
            for i in 1 to line_len loop
                if line_str(i) = ':' then
                    is_label := true;
                    temp_cmd.cmd := CMD_LABEL;
                    temp_cmd.label(1 to i-1) := line_str(1 to i-1);
                    temp_cmd.label_len := i-1;
                    exit;
                end if;
            end loop;
            
            if not is_label then
                -- Parse command line: [opcode] [address] [data]
                pos := 1;
                word_count := 0;
                
                -- Skip leading spaces
                while pos <= line_len and line_str(pos) = ' ' loop
                    pos := pos + 1;
                end loop;
                
                -- Parse words
                while pos <= line_len and word_count < 3 loop
                    word_start := pos;
                    
                    -- Find end of word
                    while pos <= line_len and line_str(pos) /= ' ' loop
                        pos := pos + 1;
                    end loop;
                    word_end := pos - 1;
                    
                    -- Process word based on position
                    if word_count = 0 then
                        -- Opcode
                        cmd_str(1 to word_end-word_start+1) := line_str(word_start to word_end);
                        temp_cmd.cmd := str_to_cmd(cmd_str(1 to word_end-word_start+1));
                    elsif word_count = 1 then
                        -- Address or Label (for GOTO/BRANCH)
                        addr_str(1 to word_end-word_start+1) := line_str(word_start to word_end);
                        if temp_cmd.cmd = CMD_GOTO or temp_cmd.cmd = CMD_BRANCH then
                            temp_cmd.label(1 to word_end-word_start+1) := line_str(word_start to word_end);
                            temp_cmd.label_len := word_end-word_start+1;
                        else
                            -- Convert hex string to address (simplified)
                            temp_cmd.addr := std_logic_vector(to_unsigned(0, ADDR_WIDTH)); -- Placeholder
                        end if;
                    elsif word_count = 2 then
                        -- Data
                        data_str(1 to word_end-word_start+1) := line_str(word_start to word_end);
                        -- Convert hex string to data (simplified)
                        temp_cmd.data := std_logic_vector(to_unsigned(0, DATA_WIDTH)); -- Placeholder
                    end if;
                    
                    word_count := word_count + 1;
                    
                    -- Skip spaces
                    while pos <= line_len and line_str(pos) = ' ' loop
                        pos := pos + 1;
                    end loop;
                end loop;
            end if;
            
            cmd_memory(cmd_idx) <= temp_cmd;
            cmd_idx := cmd_idx + 1;
        end loop;
        
        cmd_count <= cmd_idx;
        file_close(test_file);
    end procedure;

begin

    -- Main Process
    main_proc: process(clk, rst_n)
        variable target_addr : integer;
    begin
        if rst_n = '0' then
            state <= IDLE;
            pc <= 0;
            done <= '0';
            error <= '0';
            psel <= '0';
            penable <= '0';
            pwrite <= '0';
            paddr <= (others => '0');
            pwdata <= (others => '0');
            file_loaded <= false;
            cmd_count <= 0;
            label_count <= 0;
            
        elsif rising_edge(clk) then
            case state is
                when IDLE =>
                    done <= '0';
                    error <= '0';
                    psel <= '0';
                    penable <= '0';
                    if start = '1' then
                        if not file_loaded then
                            state <= LOAD_FILE;
                        else
                            state <= EXECUTE;
                        end if;
                        pc <= 0;
                    end if;
                
                when LOAD_FILE =>
                    -- File loading would be done here in simulation
                    -- For synthesis, commands would need to be pre-loaded
                    file_loaded <= true;
                    state <= PARSE_LABELS;
                
                when PARSE_LABELS =>
                    -- Build label table
                    label_count <= 0;
                    for i in 0 to cmd_count-1 loop
                        if cmd_memory(i).cmd = CMD_LABEL then
                            label_table(label_count).name <= cmd_memory(i).label;
                            label_table(label_count).name_len <= cmd_memory(i).label_len;
                            label_table(label_count).addr <= i;
                            label_table(label_count).valid <= true;
                            label_count <= label_count + 1;
                        end if;
                    end loop;
                    state <= EXECUTE;
                
                when EXECUTE =>
                    if pc >= cmd_count then
                        state <= COMPLETE;
                    else
                        current_cmd <= cmd_memory(pc);
                        case cmd_memory(pc).cmd is
                            when CMD_WRITE =>
                                state <= APB_SETUP;
                                pwrite <= '1';
                                paddr <= cmd_memory(pc).addr;
                                pwdata <= cmd_memory(pc).data;
                            
                            when CMD_READ =>
                                state <= APB_SETUP;
                                pwrite <= '0';
                                paddr <= cmd_memory(pc).addr;
                            
                            when CMD_GOTO =>
                                target_addr := find_label(cmd_memory(pc).label, cmd_memory(pc).label_len);
                                if target_addr >= 0 then
                                    pc <= target_addr;
                                else
                                    state <= ERROR_STATE;
                                end if;
                            
                            when CMD_BRANCH =>
                                if branch_condition = '1' then
                                    target_addr := find_label(cmd_memory(pc).label, cmd_memory(pc).label_len);
                                    if target_addr >= 0 then
                                        pc <= target_addr;
                                    else
                                        state <= ERROR_STATE;
                                    end if;
                                else
                                    pc <= pc + 1;
                                end if;
                            
                            when CMD_LABEL =>
                                pc <= pc + 1; -- Skip labels during execution
                            
                            when others =>
                                state <= ERROR_STATE;
                        end case;
                    end if;
                
                when APB_SETUP =>
                    psel <= '1';
                    penable <= '0';
                    state <= APB_ACCESS;
                
                when APB_ACCESS =>
                    penable <= '1';
                    state <= APB_WAIT;
                
                when APB_WAIT =>
                    if pready = '1' then
                        if pslverr = '1' then
                            state <= ERROR_STATE;
                        else
                            if current_cmd.cmd = CMD_READ then
                                last_read_data <= prdata;
                                -- Simple branch condition: branch if read data is non-zero
                                if unsigned(prdata) /= 0 then
                                    branch_condition <= '1';
                                else
                                    branch_condition <= '0';
                                end if;
                            end if;
                            psel <= '0';
                            penable <= '0';
                            pc <= pc + 1;
                            state <= EXECUTE;
                        end if;
                    end if;
                
                when COMPLETE =>
                    done <= '1';
                
                when ERROR_STATE =>
                    error <= '1';
                    psel <= '0';
                    penable <= '0';
                
                when others =>
                    state <= ERROR_STATE;
            end case;
        end if;
    end process;

end architecture behavioral;