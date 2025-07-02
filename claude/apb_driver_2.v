module apb_bus_driver #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter TEST_FILE = "test_commands.txt",
    parameter MAX_COMMANDS = 1024,
    parameter MAX_LABELS = 256,
    parameter MAX_LINE_LENGTH = 256
)(
    // Clock and Reset
    input  wire                     clk,
    input  wire                     rst_n,
    
    // APB Master Interface
    output reg  [ADDR_WIDTH-1:0]    paddr,
    output reg                      psel,
    output reg                      penable,
    output reg                      pwrite,
    output reg  [DATA_WIDTH-1:0]    pwdata,
    input  wire                     pready,
    input  wire [DATA_WIDTH-1:0]    prdata,
    input  wire                     pslverr,
    
    // Control Signals
    input  wire                     start,
    output reg                      done,
    output reg                      error
);

    // Command Types
    localparam CMD_WRITE   = 3'b000;
    localparam CMD_READ    = 3'b001;
    localparam CMD_BRANCH  = 3'b010;
    localparam CMD_GOTO    = 3'b011;
    localparam CMD_LABEL   = 3'b100;
    localparam CMD_INVALID = 3'b111;

    // State Machine States
    localparam IDLE        = 4'b0000;
    localparam LOAD_FILE   = 4'b0001;
    localparam PARSE_LABELS = 4'b0010;
    localparam EXECUTE     = 4'b0011;
    localparam APB_SETUP   = 4'b0100;
    localparam APB_ACCESS  = 4'b0101;
    localparam APB_WAIT    = 4'b0110;
    localparam BRANCH_EVAL = 4'b0111;
    localparam COMPLETE    = 4'b1000;
    localparam ERROR_STATE = 4'b1001;

    // Command Memory Structure
    reg [2:0]               cmd_memory_cmd [0:MAX_COMMANDS-1];
    reg [ADDR_WIDTH-1:0]    cmd_memory_addr [0:MAX_COMMANDS-1];
    reg [DATA_WIDTH-1:0]    cmd_memory_data [0:MAX_COMMANDS-1];
    reg [255:0]             cmd_memory_label [0:MAX_COMMANDS-1];  // 32 chars * 8 bits
    reg [7:0]               cmd_memory_label_len [0:MAX_COMMANDS-1];

    // Label Table
    reg [255:0]             label_table_name [0:MAX_LABELS-1];
    reg [7:0]               label_table_name_len [0:MAX_LABELS-1];
    reg [15:0]              label_table_addr [0:MAX_LABELS-1];
    reg                     label_table_valid [0:MAX_LABELS-1];

    // Internal Signals
    reg [3:0]               state;
    reg [15:0]              pc;                 // Program Counter
    reg [15:0]              cmd_count;
    reg [7:0]               label_count;
    reg                     file_loaded;
    reg                     branch_condition;
    reg [DATA_WIDTH-1:0]    last_read_data;

    // Current command signals
    reg [2:0]               current_cmd;
    reg [ADDR_WIDTH-1:0]    current_addr;
    reg [DATA_WIDTH-1:0]    current_data;
    reg [255:0]             current_label;
    reg [7:0]               current_label_len;

    // File reading variables
    integer                 file_handle;
    integer                 scan_result;
    reg [MAX_LINE_LENGTH*8-1:0] line_buffer;
    reg [MAX_LINE_LENGTH*8-1:0] opcode_str;
    reg [MAX_LINE_LENGTH*8-1:0] addr_str;
    reg [MAX_LINE_LENGTH*8-1:0] data_str;
    reg [MAX_LINE_LENGTH*8-1:0] label_str;
    
    // Parsing variables
    integer                 i, j, k;
    integer                 line_pos;
    integer                 word_start, word_end;
    integer                 temp_addr, temp_data;
    integer                 target_addr;
    reg                     found_label;

    // Function to convert string to command type
    function [2:0] str_to_cmd;
        input [MAX_LINE_LENGTH*8-1:0] cmd_str;
        reg [63:0] cmd_word;
        begin
            cmd_word = cmd_str[63:0]; // Take first 8 characters
            case (cmd_word)
                64'h5752495445000000, // "WRITE"
                64'h7772697465000000: // "write"
                    str_to_cmd = CMD_WRITE;
                64'h5245414400000000, // "READ"
                64'h7265616400000000: // "read"
                    str_to_cmd = CMD_READ;
                64'h4252414E43480000, // "BRANCH"
                64'h6272616E63680000: // "branch"
                    str_to_cmd = CMD_BRANCH;
                64'h474F544F00000000, // "GOTO"
                64'h676F746F00000000: // "goto"
                    str_to_cmd = CMD_GOTO;
                default:
                    str_to_cmd = CMD_INVALID;
            endcase
        end
    endfunction

    // Function to find label address
    function [15:0] find_label;
        input [255:0] name;
        input [7:0] len;
        integer idx;
        begin
            find_label = 16'hFFFF; // Invalid address
            for (idx = 0; idx < MAX_LABELS; idx = idx + 1) begin
                if (label_table_valid[idx] && 
                    label_table_name_len[idx] == len &&
                    label_table_name[idx][len*8-1:0] == name[len*8-1:0]) begin
                    find_label = label_table_addr[idx];
                    idx = MAX_LABELS; // break
                end
            end
        end
    endfunction

    // Function to convert hex string to integer
    function [31:0] hex_str_to_int;
        input [MAX_LINE_LENGTH*8-1:0] hex_str;
        integer idx;
        reg [7:0] char;
        begin
            hex_str_to_int = 0;
            for (idx = 0; idx < MAX_LINE_LENGTH; idx = idx + 1) begin
                char = hex_str[idx*8 +: 8];
                if (char == 8'h00) begin
                    idx = MAX_LINE_LENGTH; // break
                end else if (char >= "0" && char <= "9") begin
                    hex_str_to_int = (hex_str_to_int << 4) + (char - "0");
                end else if (char >= "A" && char <= "F") begin
                    hex_str_to_int = (hex_str_to_int << 4) + (char - "A" + 10);
                end else if (char >= "a" && char <= "f") begin
                    hex_str_to_int = (hex_str_to_int << 4) + (char - "a" + 10);
                end else if (char == "x" || char == "X") begin
                    // Skip 0x prefix
                    hex_str_to_int = 0;
                end
            end
        end
    endfunction

    // Initialize memory arrays
    initial begin
        // Initialize command memory
        for (i = 0; i < MAX_COMMANDS; i = i + 1) begin
            cmd_memory_cmd[i] = CMD_INVALID;
            cmd_memory_addr[i] = {ADDR_WIDTH{1'b0}};
            cmd_memory_data[i] = {DATA_WIDTH{1'b0}};
            cmd_memory_label[i] = 256'h0;
            cmd_memory_label_len[i] = 8'h0;
        end
        
        // Initialize label table
        for (i = 0; i < MAX_LABELS; i = i + 1) begin
            label_table_name[i] = 256'h0;
            label_table_name_len[i] = 8'h0;
            label_table_addr[i] = 16'h0;
            label_table_valid[i] = 1'b0;
        end
    end

    // Main State Machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            pc <= 16'h0;
            done <= 1'b0;
            error <= 1'b0;
            psel <= 1'b0;
            penable <= 1'b0;
            pwrite <= 1'b0;
            paddr <= {ADDR_WIDTH{1'b0}};
            pwdata <= {DATA_WIDTH{1'b0}};
            file_loaded <= 1'b0;
            cmd_count <= 16'h0;
            label_count <= 8'h0;
            branch_condition <= 1'b0;
            last_read_data <= {DATA_WIDTH{1'b0}};
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
                        pc <= 16'h0;
                    end
                end

                LOAD_FILE: begin
                    // Load and parse test file
                    file_handle = $fopen(TEST_FILE, "r");
                    if (file_handle == 0) begin
                        state <= ERROR_STATE;
                    end else begin
                        cmd_count <= 16'h0;
                        j = 0; // Command index
                        
                        while (!$feof(file_handle) && j < MAX_COMMANDS) begin
                            // Read line
                            scan_result = $fgets(line_buffer, file_handle);
                            if (scan_result == 0) break;
                            
                            // Skip empty lines and comments
                            if (line_buffer[7:0] == 8'h0A || line_buffer[7:0] == 8'h0D || 
                                line_buffer[7:0] == 8'h23) begin // newline or '#'
                                continue;
                            end
                            
                            // Check for label (contains ':')
                            found_label = 1'b0;
                            for (k = 0; k < MAX_LINE_LENGTH; k = k + 1) begin
                                if (line_buffer[k*8 +: 8] == 8'h3A) begin // ':'
                                    found_label = 1'b1;
                                    cmd_memory_cmd[j] = CMD_LABEL;
                                    cmd_memory_label[j][k*8-1:0] = line_buffer[k*8-1:0];
                                    cmd_memory_label_len[j] = k;
                                    k = MAX_LINE_LENGTH; // break
                                end
                            end
                            
                            if (!found_label) begin
                                // Parse command line
                                scan_result = $sscanf(line_buffer, "%s %s %s", opcode_str, addr_str, data_str);
                                if (scan_result >= 2) begin
                                    cmd_memory_cmd[j] = str_to_cmd(opcode_str);
                                    
                                    if (cmd_memory_cmd[j] == CMD_GOTO || cmd_memory_cmd[j] == CMD_BRANCH) begin
                                        // Store label name for GOTO/BRANCH
                                        cmd_memory_label[j] = addr_str;
                                        // Calculate label length
                                        cmd_memory_label_len[j] = 0;
                                        for (k = 0; k < MAX_LINE_LENGTH; k = k + 1) begin
                                            if (addr_str[k*8 +: 8] == 8'h00) begin
                                                cmd_memory_label_len[j] = k;
                                                k = MAX_LINE_LENGTH; // break
                                            end
                                        end
                                    end else begin
                                        // Convert address and data
                                        cmd_memory_addr[j] = hex_str_to_int(addr_str);
                                        if (scan_result >= 3) begin
                                            cmd_memory_data[j] = hex_str_to_int(data_str);
                                        end
                                    end
                                end
                            end
                            
                            j = j + 1;
                        end
                        
                        cmd_count <= j;
                        $fclose(file_handle);
                        file_loaded <= 1'b1;
                        state <= PARSE_LABELS;
                    end
                end

                PARSE_LABELS: begin
                    // Build label table
                    label_count <= 8'h0;
                    k = 0; // Label index
                    for (i = 0; i < cmd_count && k < MAX_LABELS; i = i + 1) begin
                        if (cmd_memory_cmd[i] == CMD_LABEL) begin
                            label_table_name[k] = cmd_memory_label[i];
                            label_table_name_len[k] = cmd_memory_label_len[i];
                            label_table_addr[k] = i;
                            label_table_valid[k] = 1'b1;
                            k = k + 1;
                        end
                    end
                    label_count <= k;
                    state <= EXECUTE;
                end

                EXECUTE: begin
                    if (pc >= cmd_count) begin
                        state <= COMPLETE;
                    end else begin
                        // Load current command
                        current_cmd = cmd_memory_cmd[pc];
                        current_addr = cmd_memory_addr[pc];
                        current_data = cmd_memory_data[pc];
                        current_label = cmd_memory_label[pc];
                        current_label_len = cmd_memory_label_len[pc];
                        
                        case (current_cmd)
                            CMD_WRITE: begin
                                state <= APB_SETUP;
                                pwrite <= 1'b1;
                                paddr <= current_addr;
                                pwdata <= current_data;
                            end
                            
                            CMD_READ: begin
                                state <= APB_SETUP;
                                pwrite <= 1'b0;
                                paddr <= current_addr;
                            end
                            
                            CMD_GOTO: begin
                                target_addr = find_label(current_label, current_label_len);
                                if (target_addr != 16'hFFFF) begin
                                    pc <= target_addr;
                                end else begin
                                    state <= ERROR_STATE;
                                end
                            end
                            
                            CMD_BRANCH: begin
                                if (branch_condition) begin
                                    target_addr = find_label(current_label, current_label_len);
                                    if (target_addr != 16'hFFFF) begin
                                        pc <= target_addr;
                                    end else begin
                                        state <= ERROR_STATE;
                                    end
                                end else begin
                                    pc <= pc + 1'b1;
                                end
                            end
                            
                            CMD_LABEL: begin
                                pc <= pc + 1'b1; // Skip labels during execution
                            end
                            
                            default: begin
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
                            state <= ERROR_STATE;
                        end else begin
                            if (current_cmd == CMD_READ) begin
                                last_read_data <= prdata;
                                // Simple branch condition: branch if read data is non-zero
                                branch_condition <= |prdata;
                            end
                            psel <= 1'b0;
                            penable <= 1'b0;
                            pc <= pc + 1'b1;
                            state <= EXECUTE;
                        end
                    end
                end

                COMPLETE: begin
                    done <= 1'b1;
                end

                ERROR_STATE: begin
                    error <= 1'b1;
                    psel <= 1'b0;
                    penable <= 1'b0;
                end

                default: begin
                    state <= ERROR_STATE;
                end
            endcase
        end
    end

endmodule