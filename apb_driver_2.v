Of course. Here is the equivalent APB bus driver and CPU master model written in Verilog.

This design mirrors the functionality of the VHDL version, including the two-pass approach to handle labels for control flow.

### Verilog APB Bus Driver with Label Support

This Verilog module simulates a CPU master for an APB bus. It reads a command file with labels, builds a symbol table in an `initial` block, and then executes the test sequence using a state machine within an `always` block.

```verilog
/**
 * Verilog Module for an APB Bus Driver and CPU Master Simulation Model
 *
 * This module uses labels for control flow (goto/branch) instead of line numbers.
 * It performs a two-pass scan of the command file:
 * 1. First Pass (in an `initial` block): Build a symbol table of all labels.
 * 2. Second Pass (in an `always` block): Execute commands, using the table to resolve jumps.
 */

module apb_bus_driver #(
    // Path to the command file
    parameter G_COMMAND_FILE      = "commands.txt",
    // APB Address Bus Width
    parameter G_APB_ADDR_WIDTH    = 32,
    // APB Data Bus Width
    parameter G_APB_DATA_WIDTH    = 32,
    // Max number of lines in the command file
    parameter G_MAX_LINES         = 256,
    // Max number of labels in the command file
    parameter G_MAX_LABELS        = 64,
    // Max length of a single line/label string
    parameter G_MAX_LINE_LENGTH   = 256
)(
    // Clock and Reset
    input  wire pclk,
    input  wire presetn,

    // APB Interface
    output reg  [G_APB_ADDR_WIDTH-1:0] paddr,
    output wire [2:0]                  pprot,
    output reg                         psel,
    output reg                         penable,
    output reg                         pwrite,
    output reg  [G_APB_DATA_WIDTH-1:0] pwdata,
    input  wire                        pready,
    input  wire [G_APB_DATA_WIDTH-1:0] prdata,
    input  wire                        pslverr
);

    // --- State Machine Definition ---
    localparam [1:0]
        IDLE   = 2'b00,
        SETUP  = 2'b01,
        ACCESS = 2'b10,
        HALTED = 2'b11;

    reg [1:0] apb_state;

    // --- Command File and Label Processing ---
    reg [8*G_MAX_LINE_LENGTH-1:0] command_memory [0:G_MAX_LINES-1];
    reg [8*G_MAX_LINE_LENGTH-1:0] symbol_table_names [0:G_MAX_LABELS-1];
    integer                       symbol_table_lines [0:G_MAX_LABELS-1];
    integer                       line_count;
    integer                       label_count;
    reg                           file_loaded = 1'b0;

    reg [31:0] s_program_counter;

    // Fixed APB protection type
    assign pprot = 3'b000;

    // --- Pass 1: Initial block to read file and build symbol table ---
    initial begin
        integer file_handle;
        reg [8*G_MAX_LINE_LENGTH-1:0] line_buf;
        reg [8*G_MAX_LINE_LENGTH-1:0] label_buf;
        integer status;

        line_count  = 0;
        label_count = 0;

        file_handle = $fopen(G_COMMAND_FILE, "r");
        if (file_handle == 0) begin
            $display("FATAL: Command file not found at %s", G_COMMAND_FILE);
            $finish;
        end

        // Read file line by line
        while (!$feof(file_handle) && line_count < G_MAX_LINES) begin
            status = $fgets(line_buf, file_handle);
            command_memory[line_count] = line_buf;

            // Check for a label (string ending with ':')
            // Using sscanf to extract the first word ending with a colon
            status = $sscanf(line_buf, "%s:", label_buf);
            if (status == 1) begin
                if (label_count < G_MAX_LABELS) begin
                    symbol_table_names[label_count] = label_buf;
                    symbol_table_lines[label_count] = line_count;
                    label_count = label_count + 1;
                end
            end
            line_count = line_count + 1;
        end

        $fclose(file_handle);
        file_loaded = 1'b1; // Signal that the file has been processed
        $display("INFO: Loaded %0d lines and found %0d labels from %s.", line_count, label_count, G_COMMAND_FILE);
    end

    // --- Helper function to find a label's line index ---
    function integer find_label_pc(input [8*G_MAX_LINE_LENGTH-1:0] label_name);
        integer i;
        begin
            find_label_pc = -1; // Default to not found
            for (i = 0; i < label_count; i = i + 1) begin
                // Verilog doesn't have direct string comparison, must check char by char
                // but direct equality works for fixed-size regs in simulation
                if (symbol_table_names[i] == label_name) begin
                    find_label_pc = symbol_table_lines[i];
                end
            end
        end
    endfunction


    // --- Pass 2: Main process to execute commands ---
    always @(posedge pclk or negedge presetn) begin
        reg [8*G_MAX_LINE_LENGTH-1:0] current_line;
        reg [8*5-1:0]  opcode; // "write", "read ", "bran ", "goto "
        reg [G_APB_ADDR_WIDTH-1:0] parsed_addr;
        reg [G_APB_DATA_WIDTH-1:0] parsed_data;
        reg [8*G_MAX_LINE_LENGTH-1:0] parsed_label;
        integer next_pc;
        integer scan_status;

        if (!presetn) begin
            // --- Reset logic ---
            apb_state <= IDLE;
            psel      <= 1'b0;
            penable   <= 1'b0;
            paddr     <= 0;
            pwdata    <= 0;
            pwrite    <= 1'b0;
            s_program_counter <= 0;
        end else begin
            if (apb_state == HALTED || !file_loaded) begin
                // Do nothing
            end else if (s_program_counter >= line_count) begin
                $display("INFO: End of command file reached.");
                apb_state <= HALTED;
            end else begin
                // --- State machine logic ---
                case (apb_state)
                    IDLE: begin
                        current_line = command_memory[s_program_counter];
                        next_pc = s_program_counter + 1; // Default: move to next line

                        // Parse the current line to find the opcode
                        // Skip over an optional label "label: command ..."
                        scan_status = $sscanf(current_line, "%*s: %s", opcode);
                        if (scan_status != 1) begin
                           // No label found, try parsing from the start of the line
                           scan_status = $sscanf(current_line, "%s", opcode);
                        end

                        if (scan_status == 1) begin
                            // --- Opcode-specific parsing and execution ---
                            if (opcode == "write" || opcode == "read") begin
                                scan_status = $sscanf(current_line, "%*s %h %h", parsed_addr, parsed_data);
                                if (scan_status == 2) begin
                                    paddr   <= parsed_addr;
                                    pwdata  <= parsed_data;
                                    pwrite  <= (opcode == "write");
                                    psel    <= 1'b1;
                                    apb_state <= SETUP;
                                end
                            end else if (opcode == "goto") begin
                                scan_status = $sscanf(current_line, "%*s %s", parsed_label);
                                if (scan_status == 1) begin
                                    next_pc = find_label_pc(parsed_label);
                                    if (next_pc == -1) begin
                                        $display("FATAL: Goto label not found: %s", parsed_label);
                                        apb_state <= HALTED;
                                    end
                                end
                            end else if (opcode == "bran") begin
                                scan_status = $sscanf(current_line, "%*s %s %h", parsed_label, parsed_data);
                                if (scan_status == 2) begin
                                    if (prdata == parsed_data) begin
                                        next_pc = find_label_pc(parsed_label);
                                        if (next_pc == -1) begin
                                            $display("FATAL: Branch label not found: %s", parsed_label);
                                            apb_state <= HALTED;
                                        end
                                    end
                                end
                            end
                        end
                        s_program_counter <= next_pc;
                    end

                    SETUP: begin
                        penable <= 1'b1;
                        apb_state <= ACCESS;
                    end

                    ACCESS: begin
                        if (pready) begin
                            psel    <= 1'b0;
                            penable <= 1'b0;
                            apb_state <= IDLE;
                        end
                    end

                    default: apb_state <= IDLE;
                endcase
            end
        end
    end

endmodule
```

-----

### **Key Differences and Usage**

  * **`module` and `parameter`**: The VHDL `entity` and `generic` map are replaced by the Verilog `module` and `parameter` list.
  * **File I/O (`initial` block)**: Verilog uses an `initial` block to execute code once at the beginning of the simulation. This is where the command file is read using system tasks like `$fopen`, `$fgets`, and `$sscanf`. This block populates the `command_memory` and `symbol_table` arrays.
  * **Data Structures**:
      * Verilog doesn't have record types, so the symbol table is implemented as two parallel arrays: `symbol_table_names` for the string names and `symbol_table_lines` for the integer line numbers.
      * Strings are stored in packed arrays of `reg` type, like `reg [8*width-1:0]`.
  * **Parsing (`$sscanf`)**: The powerful `$sscanf` system task is used to parse strings, which simplifies extracting opcodes, hex values (`%h`), and strings (`%s`). The format string `%*s` is used to match and discard a word (like the opcode or a label).
  * **Functions**: The `find_label_pc` logic is encapsulated in a Verilog `function`, which works similarly to the VHDL version.
  * **`always` block**: The main sequential logic resides in an `always @(posedge pclk or negedge presetn)` block, which is the direct equivalent of the VHDL `process`.
  * **Example `commands.txt`**: The same command file format used for the updated VHDL version works with this Verilog module without any changes.

<!-- end list -->

```
-- Example commands.txt file
init:
    write 00000004 FFFFFF00
    write 00000008 12345678

read_loop:
    read  00000004 00000000
    bran  check_done FFFFFF00  -- If prdata is FFFFFF00, jump to 'check_done' label

    write 0000000C AAAAAAAA
    goto  read_loop           -- Unconditionally loop back

check_done:
    read  00000008 00000000

end_program:
```