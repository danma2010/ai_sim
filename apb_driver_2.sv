Of course. Here is the implementation upgraded to modern SystemVerilog.

This version leverages key SystemVerilog features like the `string` data type, `enum` for state machines, dynamic arrays, and associative arrays. This results in code that is significantly cleaner, more robust, and easier to read and maintain than the Verilog version.

-----

### SystemVerilog APB Bus Driver

This SystemVerilog module provides the same functionality as the previous versions but is built using modern language features for improved clarity and efficiency.

```systemverilog
/**
 * SystemVerilog Module for an APB Bus Driver and CPU Master Simulation Model
 *
 * This version is a complete rewrite in modern SystemVerilog, using:
 * - `enum` for the state machine.
 * - `string` data type for handling text.
 * - Dynamic arrays for command memory (`string cmd_mem[$]`).
 * - Associative arrays for the symbol table (`int symbol_table[string]`).
 * - `always_ff` for synchronous logic.
 */

module apb_bus_driver #(
    // Path to the command file
    parameter string G_COMMAND_FILE    = "commands.txt",
    // APB Address Bus Width
    parameter int    G_APB_ADDR_WIDTH  = 32,
    // APB Data Bus Width
    parameter int    G_APB_DATA_WIDTH  = 32
)(
    // Clock and Reset
    input  logic pclk,
    input  logic presetn,

    // APB Interface
    output logic [G_APB_ADDR_WIDTH-1:0] paddr,
    output logic [2:0]                  pprot,
    output logic                        psel,
    output logic                        penable,
    output logic                        pwrite,
    output logic [G_APB_DATA_WIDTH-1:0] pwdata,
    input  logic                        pready,
    input  logic [G_APB_DATA_WIDTH-1:0] prdata,
    input  logic                        pslverr
);

    // --- State Machine Definition using enum ---
    typedef enum logic [1:0] {
        IDLE,
        SETUP,
        ACCESS,
        HALTED
    } t_apb_state;

    t_apb_state apb_state;

    // --- Data Structures using SystemVerilog types ---
    string        cmd_mem[$];         // Dynamic array for command memory
    int           symbol_table[string]; // Associative array for label symbol table
    logic         file_loaded = 1'b0;
    int unsigned  s_program_counter;

    // Fixed APB protection type
    assign pprot = 3'b000;

    // --- Pass 1: Initial block to read file and build symbol table ---
    initial begin
        int    file_handle;
        string line_buf;
        string label_buf;
        int    line_num = 0;

        file_handle = $fopen(G_COMMAND_FILE, "r");
        if (file_handle == 0) begin
            $fatal(1, "Command file not found at %s", G_COMMAND_FILE);
        end

        // Read file line by line into the dynamic array
        while ($fgets(line_buf, file_handle)) begin
            // Trim newline character if it exists
            if (line_buf.len() > 0 && line_buf[line_buf.len()-1] == "\n") {
                line_buf = line_buf.substr(0, line_buf.len()-2);
            }
            cmd_mem.push_back(line_buf);

            // Check for a label (e.g., "my_label:")
            if ($sscanf(line_buf, "%s:", label_buf) == 1) {
                if (symbol_table.exists(label_buf)) begin
                    $warning("Duplicate label found: '%s'. Previous definition will be overwritten.", label_buf);
                end
                symbol_table[label_buf] = line_num;
            }
            line_num++;
        end

        $fclose(file_handle);
        file_loaded = 1'b1;
        $display("INFO: Loaded %0d lines and found %0d labels from %s.", cmd_mem.size(), symbol_table.num(), G_COMMAND_FILE);
    end


    // --- Pass 2: Main process to execute commands ---
    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            // --- Reset logic ---
            apb_state <= IDLE;
            psel      <= '0;
            penable   <= '0;
            paddr     <= '0;
            pwdata    <= '0;
            pwrite    <= '0;
            s_program_counter <= 0;
        end else begin
            if (apb_state == HALTED || !file_loaded) begin
                // Do nothing
            end else if (s_program_counter >= cmd_mem.size()) begin
                $display("INFO: End of command file reached at time %0t.", $time);
                apb_state <= HALTED;
            end else begin
                // --- State machine logic ---
                unique case (apb_state)
                    IDLE: begin
                        string line = cmd_mem[s_program_counter];
                        string opcode, param1;
                        logic [G_APB_ADDR_WIDTH-1:0] parsed_addr;
                        logic [G_APB_DATA_WIDTH-1:0] parsed_data;
                        int next_pc = s_program_counter + 1; // Default: move to next line

                        // Simple parsing: split line by spaces
                        string words[$] = line.split();
                        int word_idx = 0;

                        // Skip over a label if it exists
                        if (words.size() > 0 && words[0].getc(words[0].len()-1) == ":") begin
                            word_idx++;
                        end

                        if (word_idx < words.size()) begin
                            opcode = words[word_idx++];

                            // --- Opcode-specific parsing and execution ---
                            if (opcode == "write" || opcode == "read") begin
                                if (word_idx + 1 < words.size()) begin
                                    param1 = words[word_idx++];
                                    parsed_addr = param1.atohex();
                                    param1 = words[word_idx++];
                                    parsed_data = param1.atohex();

                                    paddr   <= parsed_addr;
                                    pwdata  <= parsed_data;
                                    pwrite  <= (opcode == "write");
                                    psel    <= 1'b1;
                                    apb_state <= SETUP;
                                end
                            end else if (opcode == "goto") begin
                                if (word_idx < words.size()) begin
                                    param1 = words[word_idx++]; // The label
                                    if (symbol_table.exists(param1)) begin
                                        next_pc = symbol_table[param1];
                                    end else begin
                                        $error("Goto label not found: '%s'", param1);
                                        apb_state <= HALTED;
                                    end
                                end
                            end else if (opcode == "bran") begin
                                if (word_idx + 1 < words.size()) begin
                                    param1 = words[word_idx++]; // The label
                                    string data_str = words[word_idx++];
                                    if (prdata == data_str.atohex()) begin
                                        if (symbol_table.exists(param1)) begin
                                            next_pc = symbol_table[param1];
                                        end else begin
                                            $error("Branch label not found: '%s'", param1);
                                            apb_state <= HALTED;
                                        end
                                    end
                                end
                            end
                        end
                        s_program_center <= next_pc;
                    end // case: IDLE

                    SETUP: begin
                        penable <= 1'b1;
                        apb_state <= ACCESS;
                    end

                    ACCESS: begin
                        if (pready) begin
                            psel    <= '0;
                            penable <= '0;
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

### 🌟 Key SystemVerilog Enhancements

  * **`logic` Type**: The `logic` type replaces all instances of `reg` and `wire`, simplifying declarations and reducing potential errors.
  * **`enum` for States**: The state machine (`IDLE`, `SETUP`, etc.) is defined with a strongly typed `enum`, which improves code readability and allows for better tool support and debugging.
  * **`string` Type**: All text, including lines from the file, labels, and opcodes, are handled using the flexible, built-in `string` type. This eliminates the need for fixed-size character arrays.
  * **Dynamic and Associative Arrays**:
      * The command memory (`cmd_mem`) is a **dynamic array** (`string[$]`), which automatically resizes as the file is loaded. There's no need to pre-define a maximum line count.
      * The symbol table (`symbol_table`) is an **associative array** (`int[string]`), which provides a direct and highly efficient mapping from a label `string` to its line number `int`. This completely replaces the cumbersome manual search function from the Verilog version.
  * **Simplified Parsing**: While `$sscanf` could still be used, this example uses the `.split()` string method for a different and often cleaner approach to parsing. String-to-integer conversion is handled by the built-in `.atohex()` method.
  * **`always_ff`**: The main synchronous block uses `always_ff`, clearly stating its intent to synthesize to flip-flops and enabling better linting and safety checks by design tools.
  * **Error Reporting**: The use of `$fatal`, `$error`, and `$warning` provides more semantic weight to simulation messages compared to just `$display`.

The command file format remains exactly the same as in the previous examples.