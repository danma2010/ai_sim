module apb_bus_driver_tb;

    // Parameters
    parameter int ADDR_WIDTH = 32;
    parameter int DATA_WIDTH = 32;
    parameter string TEST_FILE = "test_commands.txt";
    parameter int MAX_COMMANDS = 1024;
    parameter int MAX_LABELS = 256;
    
    // Clock and Reset
    logic clk;
    logic rst_n;
    
    // APB Interface
    logic [ADDR_WIDTH-1:0] paddr;
    logic                  psel;
    logic                  penable;
    logic                  pwrite;
    logic [DATA_WIDTH-1:0] pwdata;
    logic                  pready;
    logic [DATA_WIDTH-1:0] prdata;
    logic                  pslverr;
    
    // Control Signals
    logic start;
    logic done;
    logic error;
    
    // Testbench variables
    int test_count = 0;
    int pass_count = 0;
    int fail_count = 0;
    
    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz clock
    end
    
    // DUT instantiation
    apb_bus_driver #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .TEST_FILE(TEST_FILE),
        .MAX_COMMANDS(MAX_COMMANDS),
        .MAX_LABELS(MAX_LABELS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .paddr(paddr),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .pwdata(pwdata),
        .pready(pready),
        .prdata(prdata),
        .pslverr(pslverr),
        .start(start),
        .done(done),
        .error(error)
    );
    
    // Simple APB Slave Model
    apb_slave_model #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) slave (
        .clk(clk),
        .rst_n(rst_n),
        .paddr(paddr),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .pwdata(pwdata),
        .pready(pready),
        .prdata(prdata),
        .pslverr(pslverr)
    );
    
    // Test file creation task
    task create_test_file(string filename);
        int fd;
        fd = $fopen(filename, "w");
        if (fd == 0) begin
            $fatal("Cannot create test file: %s", filename);
        end
        
        $fwrite(fd, "# Test program for APB Bus Driver\n");
        $fwrite(fd, "# Basic write/read operations\n");
        $fwrite(fd, "WRITE 0x1000 0x12345678\n");
        $fwrite(fd, "WRITE 0x2000 0xDEADBEEF\n");
        $fwrite(fd, "READ  0x1000 0x00000000\n");
        $fwrite(fd, "READ  0x2000 0x00000000\n");
        $fwrite(fd, "\n");
        $fwrite(fd, "# Test branching\n");
        $fwrite(fd, "WRITE 0x3000 0x00000000\n");
        $fwrite(fd, "READ  0x3000 0x00000000\n");
        $fwrite(fd, "BRANCH skip_section\n");
        $fwrite(fd, "WRITE 0x4000 0xBADC0DE\n");
        $fwrite(fd, "\n");
        $fwrite(fd, "skip_section:\n");
        $fwrite(fd, "WRITE 0x5000 0xCAFEBABE\n");
        $fwrite(fd, "\n");
        $fwrite(fd, "# Test loop with goto\n");
        $fwrite(fd, "WRITE 0x6000 0x00000003\n");
        $fwrite(fd, "\n");
        $fwrite(fd, "loop_start:\n");
        $fwrite(fd, "READ  0x6000 0x00000000\n");
        $fwrite(fd, "BRANCH loop_end\n");
        $fwrite(fd, "WRITE 0x7000 0xFFFFFFFF\n");
        $fwrite(fd, "GOTO  loop_start\n");
        $fwrite(fd, "\n");
        $fwrite(fd, "loop_end:\n");
        $fwrite(fd, "WRITE 0x8000 0x12345678\n");
        
        $fclose(fd);
        $display("Created test file: %s", filename);
    endtask
    
    // Test assertion macro
    `define ASSERT(condition, message) \
        begin \
            test_count++; \
            if (condition) begin \
                pass_count++; \
                $display("PASS: %s", message); \
            end else begin \
                fail_count++; \
                $error("FAIL: %s", message); \
            end \
        end
    
    // Wait for APB transaction to complete
    task wait_apb_transaction();
        @(posedge clk);
        while (!(psel && penable && pready)) begin
            @(posedge clk);
        end
        @(posedge clk);
    endtask
    
    // Wait for done or error
    task wait_completion();
        while (!done && !error) begin
            @(posedge clk);
        end
    endtask
    
    // Reset task
    task reset_dut();
        rst_n = 0;
        start = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);
        $display("Reset completed");
    endtask
    
    // Test basic functionality
    task test_basic_operation();
        $display("\n=== Test: Basic Operation ===");
        
        reset_dut();
        
        // Start the test
        start = 1;
        @(posedge clk);
        start = 0;
        
        // Wait for completion
        wait_completion();
        
        `ASSERT(!error, "No error should occur during basic operation");
        `ASSERT(done, "Test should complete successfully");
        
        $display("Basic operation test completed\n");
    endtask
    
    // Test with invalid file
    task test_invalid_file();
        $display("\n=== Test: Invalid File ===");
        
        // Create DUT with invalid file
        apb_bus_driver #(
            .ADDR_WIDTH(ADDR_WIDTH),
            .DATA_WIDTH(DATA_WIDTH),
            .TEST_FILE("nonexistent.txt"),
            .MAX_COMMANDS(MAX_COMMANDS),
            .MAX_LABELS(MAX_LABELS)
        ) dut_invalid (
            .clk(clk),
            .rst_n(rst_n),
            .paddr(),
            .psel(),
            .penable(),
            .pwrite(),
            .pwdata(),
            .pready(1'b1),
            .prdata(32'h0),
            .pslverr(1'b0),
            .start(start),
            .done(),
            .error()
        );
        
        reset_dut();
        
        // Start the test
        start = 1;
        @(posedge clk);
        start = 0;
        
        // Wait a bit for error to be detected
        repeat(10) @(posedge clk);
        
        $display("Invalid file test completed\n");
    endtask
    
    // Test APB slave error handling
    task test_slave_error();
        $display("\n=== Test: APB Slave Error ===");
        
        reset_dut();
        
        // Configure slave to generate error on specific address
        slave.set_error_addr(32'h1000);
        
        // Start the test
        start = 1;
        @(posedge clk);
        start = 0;
        
        // Wait for completion or error
        wait_completion();
        
        `ASSERT(error, "Error should be detected when slave returns error");
        
        // Clear error condition
        slave.clear_error_addr();
        
        $display("Slave error test completed\n");
    endtask
    
    // Monitor APB transactions
    initial begin
        forever begin
            @(posedge clk);
            if (psel && penable && pready) begin
                if (pwrite) begin
                    $display("APB WRITE: addr=0x%08x, data=0x%08x", paddr, pwdata);
                end else begin
                    $display("APB READ:  addr=0x%08x, data=0x%08x", paddr, prdata);
                end
            end
        end
    end
    
    // Main test sequence
    initial begin
        $display("=== APB Bus Driver Testbench ===");
        $display("Creating test file...");
        
        // Create test file
        create_test_file(TEST_FILE);
        
        // Run tests
        test_basic_operation();
        test_slave_error();
        
        // Print results
        $display("\n=== Test Results ===");
        $display("Total tests: %0d", test_count);
        $display("Passed:      %0d", pass_count);
        $display("Failed:      %0d", fail_count);
        
        if (fail_count == 0) begin
            $display("All tests PASSED!");
        end else begin
            $display("Some tests FAILED!");
        end
        
        $display("Testbench completed");
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #1000000; // 1ms timeout
        $error("Testbench timeout!");
        $finish;
    end
    
    // Waveform dump
    initial begin
        $dumpfile("apb_bus_driver_tb.vcd");
        $dumpvars(0, apb_bus_driver_tb);
    end

endmodule

// Simple APB Slave Model
module apb_slave_model #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int MEM_SIZE = 1024
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic [ADDR_WIDTH-1:0]   paddr,
    input  logic                    psel,
    input  logic                    penable,
    input  logic                    pwrite,
    input  logic [DATA_WIDTH-1:0]   pwdata,
    output logic                    pready,
    output logic [DATA_WIDTH-1:0]   prdata,
    output logic                    pslverr
);

    // Memory array
    logic [DATA_WIDTH-1:0] memory [MEM_SIZE];
    
    // Configuration
    logic [ADDR_WIDTH-1:0] error_addr;
    logic                  error_addr_valid;
    int                    wait_cycles;
    int                    wait_counter;
    
    // Address decode
    logic [15:0] mem_addr;
    assign mem_addr = paddr[17:2]; // Word aligned, 1KB memory
    
    // APB slave logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pready <= 1'b0;
            prdata <= '0;
            pslverr <= 1'b0;
            wait_counter <= 0;
            // Initialize memory with some test patterns
            for (int i = 0; i < MEM_SIZE; i++) begin
                memory[i] <= i * 4; // Simple pattern
            end
        end else begin
            pslverr <= 1'b0;
            
            if (psel && !penable) begin
                // Setup phase
                pready <= 1'b0;
                wait_counter <= wait_cycles;
                
                // Check for error condition
                if (error_addr_valid && paddr == error_addr) begin
                    pslverr <= 1'b1;
                    pready <= 1'b1;
                end
            end else if (psel && penable) begin
                // Access phase
                if (wait_counter > 0) begin
                    wait_counter <= wait_counter - 1;
                    pready <= 1'b0;
                end else begin
                    pready <= 1'b1;
                    
                    if (!pslverr) begin
                        if (pwrite) begin
                            // Write operation
                            if (mem_addr < MEM_SIZE) begin
                                memory[mem_addr] <= pwdata;
                                $display("SLAVE: Write addr=0x%08x, data=0x%08x", 
                                        paddr, pwdata);
                            end
                        end else begin
                            // Read operation
                            if (mem_addr < MEM_SIZE) begin
                                prdata <= memory[mem_addr];
                                $display("SLAVE: Read  addr=0x%08x, data=0x%08x", 
                                        paddr, memory[mem_addr]);
                            end else begin
                                prdata <= 32'hDEADBEEF; // Out of range
                            end
                        end
                    end
                end
            end else begin
                pready <= 1'b0;
                prdata <= '0;
            end
        end
    end
    
    // Configuration tasks
    task set_error_addr(logic [ADDR_WIDTH-1:0] addr);
        error_addr = addr;
        error_addr_valid = 1'b1;
        $display("SLAVE: Error address set to 0x%08x", addr);
    endtask
    
    task clear_error_addr();
        error_addr_valid = 1'b0;
        $display("SLAVE: Error address cleared");
    endtask
    
    task set_wait_cycles(int cycles);
        wait_cycles = cycles;
        $display("SLAVE: Wait cycles set to %0d", cycles);
    endtask
    
    // Memory access tasks for verification
    task write_memory(int addr, logic [DATA_WIDTH-1:0] data);
        if (addr < MEM_SIZE) begin
            memory[addr] = data;
        end
    endtask
    
    task read_memory(int addr, output logic [DATA_WIDTH-1:0] data);
        if (addr < MEM_SIZE) begin
            data = memory[addr];
        end else begin
            data = 32'hDEADBEEF;
        end
    endtask
    
    // Initialize
    initial begin
        error_addr_valid = 1'b0;
        wait_cycles = 0;
        wait_counter = 0;
    end

endmodule