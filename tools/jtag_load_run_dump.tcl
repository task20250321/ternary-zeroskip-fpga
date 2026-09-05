# Copyright 2026 Yu Inoue
# SPDX-License-Identifier: Apache-2.0
# Run with:
# system-console --cli --project_dir=. --script=tools/jtag_load_run_dump.tcl
#
# Environment:
#   ZS_CASE_DIR     required
#   ZS_MASTER_INDEX optional, default 0

proc read_hex_lines {filename} {
    set fd [open $filename r]
    set vals {}
    while {[gets $fd line] >= 0} {
        set s [string trim $line]
        if {$s eq ""} { continue }
        scan $s %x value
        lappend vals $value
    }
    close $fd
    return $vals
}

proc write_32_chunks {master base vals {chunk_size 256}} {
    set total [llength $vals]
    set pos 0
    while {$pos < $total} {
        set end [expr {$pos + $chunk_size - 1}]
        if {$end >= $total} { set end [expr {$total - 1}] }
        set chunk [lrange $vals $pos $end]
        master_write_32 $master [expr {$base + 4*$pos}] $chunk
        set pos [expr {$end + 1}]
        if {($pos % 4096) == 0 || $pos == $total} {
            puts "  wrote $pos / $total 32-bit words"
        }
    }
}

if {![info exists ::env(ZS_CASE_DIR)]} {
    error "ZS_CASE_DIR is required"
}
set case_dir [file normalize $::env(ZS_CASE_DIR)]
set master_index 0
if {[info exists ::env(ZS_MASTER_INDEX)]} {
    set master_index $::env(ZS_MASTER_INDEX)
}

refresh_connections
set paths [get_service_paths master]
puts "Available master services:"
for {set i 0} {$i < [llength $paths]} {incr i} {
    puts "  $i: [lindex $paths $i]"
}
if {[llength $paths] == 0} {
    error "no System Console master service found"
}
if {$master_index >= [llength $paths]} {
    error "ZS_MASTER_INDEX=$master_index is out of range"
}
set master [lindex $paths $master_index]
open_service master $master
puts "Using master: $master"

set CSR_BASE      0x30000000
set ACT_BASE      0x10000000
set RESULT_BASE   0x21000000

# Signature check.
set sig [lindex [master_read_32 $master $CSR_BASE 1] 0]
puts [format "signature=0x%08X" $sig]
if {$sig != 0x5A53564D} {
    close_service master $master
    error "unexpected ZSVM signature"
}

# Wait until EMIF is ready.
set ready 0
for {set retry 0} {$retry < 200} {incr retry} {
    set status [lindex [master_read_32 $master [expr {$CSR_BASE+8}] 1] 0]
    if {$status & 1} {
        set ready 1
        break
    }
    after 50
}
if {!$ready} {
    close_service master $master
    error "EMIF ready timeout"
}

# Clear counters/state.
master_write_32 $master $CSR_BASE [list 2]
after 10

puts "Loading compressed weights to DDR4 through the host endpoint..."
set weights [read_hex_lines [file join $case_dir weight_words32.txt]]
write_32_chunks $master 0x00000000 $weights 256

puts "Loading activations..."
set acts [read_hex_lines [file join $case_dir activation_words32.txt]]
write_32_chunks $master $ACT_BASE $acts 256

# Expected outputs are not uploaded. Numerical comparison is performed
# on the host after fpga_outputs.txt is dumped.

set weight_words [lindex [master_read_32 $master [expr {$CSR_BASE+40}] 1] 0]
set act_bytes    [lindex [master_read_32 $master [expr {$CSR_BASE+44}] 1] 0]
set out_features [lindex [master_read_32 $master [expr {$CSR_BASE+16}] 1] 0]
set expected_weight_words [lindex [master_read_32 $master [expr {$CSR_BASE+32}] 1] 0]
puts "upload counters: weight256=$weight_words/$expected_weight_words activation_bytes=$act_bytes"

if {$weight_words != $expected_weight_words} {
    close_service master $master
    error "weight upload count mismatch"
}

puts "Starting accelerator..."
master_write_32 $master $CSR_BASE [list 1]

set done 0
for {set retry 0} {$retry < 12000} {incr retry} {
    set status [lindex [master_read_32 $master [expr {$CSR_BASE+8}] 1] 0]
    if {$status & 0x8} {
        set done 1
        break
    }
    after 50
}
if {!$done} {
    close_service master $master
    error "accelerator timeout"
}

set status       [lindex [master_read_32 $master [expr {$CSR_BASE+8}] 1] 0]
set outputs      [lindex [master_read_32 $master [expr {$CSR_BASE+52}] 1] 0]
set layer_cycles [lindex [master_read_32 $master [expr {$CSR_BASE+56}] 1] 0]
set core_cycles  [lindex [master_read_32 $master [expr {$CSR_BASE+60}] 1] 0]
set fetched      [lindex [master_read_32 $master [expr {$CSR_BASE+64}] 1] 0]
set delivered    [lindex [master_read_32 $master [expr {$CSR_BASE+68}] 1] 0]

puts [format "status=0x%08X outputs=%u layer_cycles=%u core_run_cycles=%u fetched=%u delivered=%u" \
    $status $outputs $layer_cycles $core_cycles $fetched $delivered]

set values [master_read_32 $master $RESULT_BASE $out_features]
set ofd [open [file join $case_dir fpga_outputs.txt] w]
for {set i 0} {$i < [llength $values]} {incr i} {
    set u [lindex $values $i]
    if {$u >= 0x80000000} {
        set s [expr {$u - 0x100000000}]
    } else {
        set s $u
    }
    puts $ofd "$i\t$s"
}
close $ofd

set sfd [open [file join $case_dir fpga_status.txt] w]
puts $sfd [format "status_hex=0x%08X" $status]
puts $sfd "outputs_captured=$outputs"
puts $sfd "layer_cycles=$layer_cycles"
puts $sfd "core_run_cycles=$core_cycles"
puts $sfd "stream_words_fetched=$fetched"
puts $sfd "stream_words_delivered=$delivered"
puts $sfd "test_pass=[expr {($status & 0x10) != 0}]"
puts $sfd "test_fail=[expr {($status & 0x20) != 0}]"
puts $sfd "numerical_compare=external_host"
close $sfd

close_service master $master
puts "FPGA dump complete: [file join $case_dir fpga_outputs.txt]"
