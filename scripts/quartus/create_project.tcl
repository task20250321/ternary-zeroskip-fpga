# Copyright 2026 Yu Inoue
# SPDX-License-Identifier: Apache-2.0

package require ::quartus::project

# ============================================================
# Arguments
# ============================================================

if {[llength $argv] != 1} {
    puts stderr "usage: quartus_sh -t create_project.tcl <zeroskip|dense>"
    exit 1
}

set arch [lindex $argv 0]

if {$arch ne "zeroskip" && $arch ne "dense"} {
    puts stderr "ERROR: architecture must be zeroskip or dense"
    exit 1
}

# scripts/quartus/create_project.tcl
#       -> repository root = ../..
set script_dir [file dirname [file normalize [info script]]]
set root       [file normalize [file join $script_dir ../..]]
set build      [pwd]

puts "============================================================"
puts "Architecture : $arch"
puts "Repository   : $root"
puts "Build dir    : $build"
puts "============================================================"

# ============================================================
# Project
# ============================================================

project_new zeroskip_top \
    -revision zeroskip_top \
    -overwrite

set_global_assignment -name FAMILY "Agilex 5"
set_global_assignment -name DEVICE A5ED013BB32AE4SR1
set_global_assignment -name TOP_LEVEL_ENTITY zeroskip_top

# PE128 configuration generated/copied by build.sh.
set_global_assignment \
    -name SEARCH_PATH \
    [file normalize [file join $build include]]

# ============================================================
# Helper
# ============================================================

proc add_sv {root rel} {
    set_global_assignment \
        -name SYSTEMVERILOG_FILE \
        [file normalize [file join $root $rel]]
}

# ============================================================
# Common RTL
# ============================================================

foreach f {
    rtl/memory/rv_fifo.sv
    rtl/lut/trit5_decode_lut.sv
    rtl/memory/pending_sum_bank.sv
    rtl/memory/activation_buffer_ram.sv
    rtl/memory/activation_prefetch_stream.sv

    rtl/memory/weight_word_fifo.sv
    rtl/memory/ddr4_weight_refill_ctrl.sv
    rtl/memory/emif_weight_streamer.sv
    rtl/memory/emif_weight_stream_to_rv.sv

    rtl/memory/zeroskip_jtag_avmm_endpoint.sv
    rtl/core/accelerator_host_case_ctrl.sv
} {
    add_sv $root $f
}

# ============================================================
# Architecture-specific RTL
# ============================================================

if {$arch eq "zeroskip"} {

    foreach f {
        rtl/core/pe_owned_word_dispatcher.sv
        rtl/core/pe_owned_key_engine.sv
        rtl/core/pe_owned_private_accumulator.sv
        rtl/core/ternary_zeroskip_pe_owned_accelerator.sv
        rtl/core/ternary_zeroskip_pe_owned_emif_wrapper.sv
    } {
        add_sv $root $f
    }

    add_sv $root top/zeroskip_top_zeroskip.sv

} else {

    foreach f {
        rtl/baseline/trit5_dense_decode_lut.sv
        rtl/baseline/dense_owned_word_dispatcher.sv
        rtl/baseline/dense_owned_key_engine.sv
        rtl/baseline/dense_owned_private_accumulator.sv
        rtl/baseline/ternary_dense_owned_accelerator.sv
        rtl/baseline/ternary_dense_owned_emif_wrapper.sv
    } {
        add_sv $root $f
    }

    add_sv $root top/zeroskip_top_dense.sv
}

# ============================================================
# Timing constraint
# ============================================================

set_global_assignment \
    -name SDC_FILE \
    [file normalize \
        [file join $root constraints/zeroskip_top.sdc]]

# ============================================================
# DDR4 EMIF IP
# ============================================================

set_global_assignment \
    -name IP_FILE \
    [file normalize \
        [file join $build ip/ddr4_emif/ddr4_emif.ip]]

# ============================================================
# JTAG-to-Avalon child IP parameterizations
# ============================================================

foreach rel {
    ip/jtag_host/ip/zeroskip_jtag_host/zeroskip_jtag_host_clock_in.ip
    ip/jtag_host/ip/zeroskip_jtag_host/zeroskip_jtag_host_master_0.ip
    ip/jtag_host/ip/zeroskip_jtag_host/zeroskip_jtag_host_reset_in.ip
} {
    set_global_assignment \
        -name IP_FILE \
        [file normalize [file join $build $rel]]
}

# Platform Designer system itself.
set_global_assignment \
    -name QSYS_FILE \
    [file normalize \
        [file join $build ip/jtag_host/zeroskip_jtag_host.qsys]]

# ============================================================
# Device / pin / fitter assignments
#
# common_assignments.tcl contains source commands whose paths are
# relative to the repository root. Temporarily change cwd while
# evaluating it.
# ============================================================

set saved_pwd [pwd]

cd $root
source [file join $root scripts/quartus/common_assignments.tcl]
cd $saved_pwd

# ============================================================
# Save project
# ============================================================

export_assignments
project_close

puts "PASS: created $arch project"
