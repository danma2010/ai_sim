module apb_bus_driver #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter string TEST_FILE = "test_commands.txt",
    parameter int MAX_COMMANDS = 1024,
    parameter int MAX_LABELS = 256
)(
    // Clock and Reset
    input  logic                    clk,
    input  logic                    rst_n,
    
    // APB Master Interface
    output logic [ADDR_WIDTH-1:0]  paddr,
    output logic                   psel,
    output logic                   penable,
    output logic                   pwrite,
    output logic [DATA_WIDTH-1:0]  pwdata,
    input  logic                   pready,
    input  logic [DATA_WIDTH-1:0]  prdata,
    input  logic                   pslverr,
    
    // Control Signals
    input  logic                   start,
    output logic                   done,
    output logic                   error
);

    // Command Types
    typedef enum logic [2:0] {
        CMD_WRITE   = 3'b000,
        CMD_READ    = 3'b001,
        CMD_BRANCH  = 3'b010,
        CMD_GOTO    = 3'b011,
        CMD_LABEL   = 3'b100,
        CMD_INVALID = 3'b111
    } cmd_type_e;

    // State Machine States
    typedef enum logic [3:0] {
        IDLE        = 4'b0000,
        LOAD_FILE   = 4'b0001,
        PARSE_LABELS = 4'b0010,
        EXECUTE     = 4'b0011,
        APB_SETUP   = 4'b0100,
        APB_ACCESS  = 4'b0101,
        APB_WAIT    = 4'b0110,
        COMPLETE    = 4'b1000,
        ERROR_STATE = 4'b1001
    } state_e;

    // Command Structure
    typedef struct packed {
        cmd_type_e              cmd;
        logic [ADDR_WIDTH-1:0]  addr;
        logic [DATA_WIDTH-1:0]  data;
        string                  label;
    } command_t;

    // Label Structure
    typedef struct packed {
        string                  name;
        int                     addr;
        logic                   valid;
    } label_t;

    // Memory and Tables
    command_t               cmd_memory [MAX_COMMANDS];
    label_t                 label_table [MAX_LABELS];

    // Internal Signals
    state_e                 state;
    int                     pc;                 // Program Counter
    int                     cmd_count;
    int                     label_count;
    logic                   file_loaded;
    logic                   branch_condition;
    logic [DATA_WIDTH-1:0]  last_read_data;

    // Current command
    command_t               current_cmd;

    // File I/O
    int                     file_handle;
    string                  line_str;
    string                  opcode_str;
    string                  addr_str;
    string                  data_str;
    string                  label_str;

    // Function to parse command string
    function cmd_type_e parse_opcode(string opcode);
        case (opcode.toupper())
            "WRITE":  return CMD_WRITE;
            "READ":   return CMD_READ;
            "BRANCH": return CMD_BRANCH;
            "GOTO":   return CMD_GOTO;
            default:  return CMD_INVALID;
        endcase
    endfunction

    // Function to convert hex string to logic vector
    function logic [31:0] hex_to_logic(string hex_str);
        logic [31:0] result = 0;
        string clean_str;
        
        // Remove 0x prefix if present
        if (hex_str.substr(0, 1) == "0x" || hex_str.substr(0, 1) == "0X")
            clean_str = hex_str.substr(2, hex_str.len()-1);
        else
            clean_str = hex_str;
            
        // Convert hex string to integer
        result = clean_str.atohex();
        return result;
    endfunction

    // Function to find label address
    function int find_label_addr(string label_name);
        for (int i = 0; i < label_count; i++) begin
            if (label_table[i].valid && label_table[i].name == label_name) begin
                return label_table[i].addr;
            end
        end
        return -1; // Label not found
    endfunction

    // Task to load and parse test file
    task load_test_file();
        string tokens[$];
        int cmd_idx = 0;
        
        file_handle = $fopen(TEST_FILE, "r");
        if (file_handle == 0) begin
            $error("Cannot open test file: %s", TEST_FILE);
            state <= ERROR_STATE;
            return;
        end

        // Initialize command memory
        foreach (cmd_memory[i]) begin
            cmd_memory[i].cmd = CMD_INVALID;
            cmd_memory[i].addr = '0;
            cmd_memory[i].data = '0;
            cmd_memory[i].label = "";
        end

        while (!$feof(file_handle) && cmd_idx < MAX_COMMANDS) begin
            if ($fgets(line_str, file_handle)) begin
                // Remove leading/trailing whitespace
                line_str = line_str.substr(0, line_str.len()-2); // Remove newline
                
                // Skip empty lines and comments
                if (line_str.len() == 0 || line_str.getc(0) == "#") begin
                    continue;
                end
                
                // Check for label (ends with ':')
                if (line_str.getc(line_str.len()-1) == ":") begin
                    cmd_memory[cmd_idx].cmd = CMD_LABEL;
                    cmd_memory[cmd_idx].label = line_str.substr(0, line_str.len()-2);
                end else begin
                    // Split line into tokens
                    tokens.delete();
                    split_string(line_str, tokens);
                    
                    if (tokens.size() >= 2) begin
                        cmd_memory[cmd_idx].cmd = parse_opcode(tokens[0]);
                        
                        case (cmd_memory[cmd_idx].cmd)
                            CMD_WRITE, CMD_READ: begin
                                cmd_memory[cmd_idx].addr = hex_to_logic(tokens[1]);
                                if (tokens.size() >= 3) begin
                                    cmd_memory[cmd_idx].data = hex_to_logic(tokens[2]);
                                end
                            end
                            CMD_GOTO, CMD_BRANCH: begin
                                cmd_memory[cmd_idx].label = tokens[1];
                            end
                            default: begin
                                cmd_memory[cmd_idx].cmd = CMD_INVALID;
                            end
                        endcase
                    end
                end
                cmd_idx++;
            end
        end
        
        cmd_count = cmd_idx;
        $fclose(file_handle);
        file_loaded = 1'b1;
        
        $display("Loaded %0d commands from %s", cmd_count, TEST_FILE);
    endtask

    // Task to split string into tokens
    task split_string(string str, ref string tokens[$]);
        string current_token = "";
        logic in_token = 1'b0;
        
        for (int i = 0; i < str.len(); i++) begin
            if (str.getc(i) == " " || str.getc(i) == "\t") begin
                if (in_token) begin
                    tokens.push_back(current_token);
                    current_token = "";
                    in_token = 1'b0;
                end
            end else begin
                current_token = {current_token, str.getc(i)};
                in_token = 1'b1;
            end
        end
        
        if (in_token) begin
            tokens.push_back(current_token);
        end
    endtask

    // Task to build label table
    task build_label_table();
        int label_idx = 0;
        
        // Initialize label table
        foreach (label_table[i]) begin
            label_table[i].name = "";
            label_table[i].addr = 0;
            label_table[i].valid = 1'b0;
        end
        
        for (int i = 0; i < cmd_count && label_idx < MAX_LABELS; i++) begin
            if (cmd_memory[i].cmd == CMD_LABEL) begin
                label_table[label_idx].name = cmd_memory[i].label;
                label_table[label_idx].addr = i;
                label_table[label_idx].valid = 1'b1;
                label_idx++;
                $display("Found label: %s at address %0d", cmd_memory[i].label, i);
            end
        end
        
        label_count = label_idx;
        $display("Built label table with %0d entries", label_count);
    endtask

    // Main State Machine
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            pc <= 0;
            done <= 1'b0;
            error <= 1'b0;
            psel <= 1'b0;
            penable <= 1'b0;
            pwrite <= 1'b0;
            paddr <= '0;
            pwdata <= '0;
            file_loaded <= 1'b0;
            cmd_count <= 0;
            label_count <= 0;
            branch_condition <= 1'b0;
            last_read_data <= '0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    error <= 1'b0;
                    psel <= 1'b0;
                    penable <= 1'b0;
                    if (start) begin
                        if (!file_loaded) begin
                            state <= LOAD_FILE;
                        end else begin
                            state <= EXECUTE;
                        end
                        pc <= 0;
                    end
                end

                LOAD_FILE: begin
                    load_test_file();
                    if (file_loaded) begin
                        state <= PARSE_LABELS;
                    end
                    // Error handling is done in the task
                end

                PARSE_LABELS: begin
                    build_label_table();
                    state <= EXECUTE;
                end

                EXECUTE: begin
                    if (pc >= cmd_count) begin
                        state <= COMPLETE;
                    end else begin
                        current_cmd = cmd_memory[pc];
                        
                        case (current_cmd.cmd)
                            CMD_WRITE: begin
                                state <= APB_SETUP;
                                pwrite <= 1'b1;
                                paddr <= current_cmd.addr;
                                pwdata <= current_cmd.data;
                                $display("WRITE: addr=0x%08x, data=0x%08x", 
                                        current_cmd.addr, current_cmd.data);
                            end
                            
                            CMD_READ: begin
                                state <= APB_SETUP;
                                pwrite <= 1'b0;
                                paddr <= current_cmd.addr;
                                $display("READ: addr=0x%08x", current_cmd.addr);
                            end
                            
                            CMD_GOTO: begin
                                int target_addr = find_label_addr(current_cmd.label);
                                if (target_addr >= 0) begin
                                    pc <= target_addr;
                                    $display("GOTO: %s (addr=%0d)", current_cmd.label, target_addr);
                                end else begin
                                    $error("Label not found: %s", current_cmd.label);
                                    state <= ERROR_STATE;
                                end
                            end
                            
                            CMD_BRANCH: begin
                                if (branch_condition) begin
                                    int target_addr = find_label_addr(current_cmd.label);
                                    if (target_addr >= 0) begin
                                        pc <= target_addr;
                                        $display("BRANCH taken: %s (addr=%0d)", 
                                                current_cmd.label, target_addr);
                                    end else begin
                                        $error("Label not found: %s", current_cmd.label);
                                        state <= ERROR_STATE;
                                    end
                                end else begin
                                    pc <= pc + 1;
                                    $display("BRANCH not taken: %s", current_cmd.label);
                                end
                            end
                            
                            CMD_LABEL: begin
                                pc <= pc + 1; // Skip labels during execution
                                $display("LABEL: %s", current_cmd.label);
                            end
                            
                            default: begin
                                $error("Invalid command at PC=%0d", pc);
                                state <= ERROR_STATE;
                            end
                        endcase
                    end
                end

                APB_SETUP: begin
                    psel <= 1'b1;
                    penable <= 1'b0;
                    state <= APB_ACCESS;
                end

                APB_ACCESS: begin
                    penable <= 1'b1;
                    state <= APB_WAIT;
                end

                APB_WAIT: begin
                    if (pready) begin
                        if (pslverr) begin
                            $error("APB slave error at address 0x%08x", paddr);
                            state <= ERROR_STATE;
                        end else begin
                            if (current_cmd.cmd == CMD_READ) begin
                                last_read_data <= prdata;
                                // Branch condition: branch if read data is non-zero
                                branch_condition <= |prdata;
                                $display("READ result: 0x%08x, branch_condition=%b", 
                                        prdata, |prdata);
                            end
                            psel <= 1'b0;
                            penable <= 1'b0;
                            pc <= pc + 1;
                            state <= EXECUTE;
                        end
                    end
                end

                COMPLETE: begin
                    done <= 1'b1;
                    $display("Program execution completed");
                end

                ERROR_STATE: begin
                    error <= 1'b1;
                    psel <= 1'b0;
                    penable <= 1'b0;
                    $display("Error state reached");
                end

                default: begin
                    state <= ERROR_STATE;
                end
            endcase
        end
    end

    // Debug: Display command memory after loading
    initial begin
        #1; // Wait for reset
        @(posedge file_loaded);
        $display("\n=== Command Memory ===");
        for (int i = 0; i < cmd_count; i++) begin
            case (cmd_memory[i].cmd)
                CMD_WRITE:  $display("%2d: WRITE  0x%08x 0x%08x", 
                                   i, cmd_memory[i].addr, cmd_memory[i].data);
                CMD_READ:   $display("%2d: READ   0x%08x", 
                                   i, cmd_memory[i].addr);
                CMD_BRANCH: $display("%2d: BRANCH %s", 
                                   i, cmd_memory[i].label);
                CMD_GOTO:   $display("%2d: GOTO   %s", 
                                   i, cmd_memory[i].label);
                CMD_LABEL:  $display("%2d: %s:", 
                                   i, cmd_memory[i].label);
                default:    $display("%2d: INVALID", i);
            endcase
        end
        $display("======================\n");
    end

endmodule