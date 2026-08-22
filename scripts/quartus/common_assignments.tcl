# Generated from the validated Quartus project.
# RTL/IP assignments are intentionally excluded.

set_global_assignment -name LAST_QUARTUS_VERSION "26.1.0 Pro Edition"
# ============================================================
# Device and project


set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files

set_global_assignment -name MIN_CORE_JUNCTION_TEMP 0
set_global_assignment -name MAX_CORE_JUNCTION_TEMP 100
set_global_assignment -name ERROR_CHECK_FREQUENCY_DIVISOR 256

# RTL sources








# 50 MHz clock

set_location_assignment PIN_D8 -to CLOCK_50
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to CLOCK_50

# FPGA reset button


# Slide switches



# Red LEDs
# Active-low


set_global_assignment -name PWRMGT_VOLTAGE_OUTPUT_FORMAT "LINEAR FORMAT"
set_global_assignment -name PWRMGT_LINEAR_FORMAT_N "-12"
set_global_assignment -name BOARD default

# DE25-Standard configuration-bank oscillator
set_global_assignment -name DEVICE_INITIALIZATION_CLOCK OSC_CLK_1_125MHZ

# Temporary EMIF placement-isolation assignments
# Remove these after EMIF pin placement is established.

# Restore board GPIO after EMIF placement validation







set_location_assignment PIN_BM78 -to CPU_RESET_n
set_instance_assignment -name IO_STANDARD "1.2-V" -to CPU_RESET_n -entity zeroskip_top

set_location_assignment PIN_BM62 -to SW[0]
set_location_assignment PIN_BP62 -to SW[1]
set_location_assignment PIN_BH62 -to SW[2]
set_location_assignment PIN_BH59 -to SW[3]
set_location_assignment PIN_BM59 -to SW[4]
set_location_assignment PIN_BK59 -to SW[5]
set_location_assignment PIN_BU62 -to SW[6]
set_location_assignment PIN_CF59 -to SW[7]
set_location_assignment PIN_BU59 -to SW[8]
set_location_assignment PIN_BR59 -to SW[9]

set_instance_assignment -name IO_STANDARD "1.2-V" -to SW[*] -entity zeroskip_top

set_location_assignment PIN_CC71 -to LEDR[0]
set_location_assignment PIN_BH78 -to LEDR[1]
set_location_assignment PIN_CH69 -to LEDR[2]
set_location_assignment PIN_CF69 -to LEDR[3]
set_location_assignment PIN_CA62 -to LEDR[4]
set_location_assignment PIN_CC62 -to LEDR[5]
set_location_assignment PIN_CF62 -to LEDR[6]
set_location_assignment PIN_BM69 -to LEDR[7]
set_location_assignment PIN_CA71 -to LEDR[8]
set_location_assignment PIN_BR62 -to LEDR[9]

set_instance_assignment -name IO_STANDARD "1.2-V" -to LEDR[*] -entity zeroskip_top

# Final DDR4 exact pin assignments
source constraints/de25_ddr4_final_pins.qsf

# ============================================================
# Shared-psum accelerator DDR4 hardware integration test
# ============================================================


# ============================================================
# DDR word-order and dynamic-PE-assignment hardware test
# ============================================================


# ============================================================
# Final parameterized BitNet hardware verification
# ============================================================



# Activation storage in M20K

# ============================================================
# Activation M20K + background prefetch
# ============================================================


