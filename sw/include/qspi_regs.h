// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Generated from docs/regs.yaml by docs/gen_regmap.py -- DO NOT EDIT.
// Register byte offsets, bit fields and field encodings of the QSPI
// controller. The SoC-specific base address and register accessors
// live with the consuming SDK (e.g. hatch: software/sdk/include/qspi.h).

#ifndef QSPI_REGS_H
#define QSPI_REGS_H

// CR: Control Register
#define QSPI_CR_OFFSET  0x00u
#define QSPI_CR_RESET   0x00000000u
#define QSPI_CR_EN  (1u << 0)
#define QSPI_CR_ABORT  (1u << 1)
#define QSPI_CR_PRESCALER_SHIFT  8u
#define QSPI_CR_PRESCALER_MASK   (0xFFu << 8u)
#define QSPI_CR_PRESCALER(v)     (((uint32_t)(v) & 0xFFu) << 8u)
#define QSPI_CR_PRESCALER_GET(r) (((uint32_t)(r) >> 8u) & 0xFFu)

// DCR: Device Configuration Register
#define QSPI_DCR_OFFSET  0x04u
#define QSPI_DCR_RESET   0x00000010u
#define QSPI_DCR_FSIZE_SHIFT  0u
#define QSPI_DCR_FSIZE_MASK   (0x1Fu << 0u)
#define QSPI_DCR_FSIZE(v)     (((uint32_t)(v) & 0x1Fu) << 0u)
#define QSPI_DCR_FSIZE_GET(r) (((uint32_t)(r) >> 0u) & 0x1Fu)
#define QSPI_DCR_CSHT_SHIFT  8u
#define QSPI_DCR_CSHT_MASK   (0x7u << 8u)
#define QSPI_DCR_CSHT(v)     (((uint32_t)(v) & 0x7u) << 8u)
#define QSPI_DCR_CSHT_GET(r) (((uint32_t)(r) >> 8u) & 0x7u)

// SR: Status Register (read-only)
#define QSPI_SR_OFFSET  0x08u
#define QSPI_SR_RESET   0x00000000u
#define QSPI_SR_TEF  (1u << 0)
#define QSPI_SR_TCF  (1u << 1)
#define QSPI_SR_BUSY  (1u << 5)
#define QSPI_SR_FLEVEL_SHIFT  8u
#define QSPI_SR_FLEVEL_MASK   (0x3Fu << 8u)
#define QSPI_SR_FLEVEL(v)     (((uint32_t)(v) & 0x3Fu) << 8u)
#define QSPI_SR_FLEVEL_GET(r) (((uint32_t)(r) >> 8u) & 0x3Fu)

// FCR: Flag Clear Register
#define QSPI_FCR_OFFSET  0x0Cu
#define QSPI_FCR_RESET   0x00000000u
#define QSPI_FCR_CTEF  (1u << 0)
#define QSPI_FCR_CTCF  (1u << 1)

// DLR: Data Length Register
#define QSPI_DLR_OFFSET  0x10u
#define QSPI_DLR_RESET   0x00000000u

// CCR: Communication Configuration Register (frame format + functional mode)
#define QSPI_CCR_OFFSET  0x14u
#define QSPI_CCR_RESET   0x00000000u
#define QSPI_CCR_INSTRUCTION_SHIFT  0u
#define QSPI_CCR_INSTRUCTION_MASK   (0xFFu << 0u)
#define QSPI_CCR_INSTRUCTION(v)     (((uint32_t)(v) & 0xFFu) << 0u)
#define QSPI_CCR_INSTRUCTION_GET(r) (((uint32_t)(r) >> 0u) & 0xFFu)
#define QSPI_CCR_IMODE_SHIFT  8u
#define QSPI_CCR_IMODE_MASK   (0x3u << 8u)
#define QSPI_CCR_IMODE(v)     (((uint32_t)(v) & 0x3u) << 8u)
#define QSPI_CCR_IMODE_GET(r) (((uint32_t)(r) >> 8u) & 0x3u)
#define QSPI_CCR_ADMODE_SHIFT  10u
#define QSPI_CCR_ADMODE_MASK   (0x3u << 10u)
#define QSPI_CCR_ADMODE(v)     (((uint32_t)(v) & 0x3u) << 10u)
#define QSPI_CCR_ADMODE_GET(r) (((uint32_t)(r) >> 10u) & 0x3u)
#define QSPI_CCR_ADSIZE_SHIFT  12u
#define QSPI_CCR_ADSIZE_MASK   (0x3u << 12u)
#define QSPI_CCR_ADSIZE(v)     (((uint32_t)(v) & 0x3u) << 12u)
#define QSPI_CCR_ADSIZE_GET(r) (((uint32_t)(r) >> 12u) & 0x3u)
#define QSPI_CCR_ABMODE_SHIFT  14u
#define QSPI_CCR_ABMODE_MASK   (0x3u << 14u)
#define QSPI_CCR_ABMODE(v)     (((uint32_t)(v) & 0x3u) << 14u)
#define QSPI_CCR_ABMODE_GET(r) (((uint32_t)(r) >> 14u) & 0x3u)
#define QSPI_CCR_ABSIZE_SHIFT  16u
#define QSPI_CCR_ABSIZE_MASK   (0x3u << 16u)
#define QSPI_CCR_ABSIZE(v)     (((uint32_t)(v) & 0x3u) << 16u)
#define QSPI_CCR_ABSIZE_GET(r) (((uint32_t)(r) >> 16u) & 0x3u)
#define QSPI_CCR_DCYC_SHIFT  18u
#define QSPI_CCR_DCYC_MASK   (0x1Fu << 18u)
#define QSPI_CCR_DCYC(v)     (((uint32_t)(v) & 0x1Fu) << 18u)
#define QSPI_CCR_DCYC_GET(r) (((uint32_t)(r) >> 18u) & 0x1Fu)
#define QSPI_CCR_DMODE_SHIFT  24u
#define QSPI_CCR_DMODE_MASK   (0x3u << 24u)
#define QSPI_CCR_DMODE(v)     (((uint32_t)(v) & 0x3u) << 24u)
#define QSPI_CCR_DMODE_GET(r) (((uint32_t)(r) >> 24u) & 0x3u)
#define QSPI_CCR_FMODE_SHIFT  26u
#define QSPI_CCR_FMODE_MASK   (0x3u << 26u)
#define QSPI_CCR_FMODE(v)     (((uint32_t)(v) & 0x3u) << 26u)
#define QSPI_CCR_FMODE_GET(r) (((uint32_t)(r) >> 26u) & 0x3u)

// AR: Address Register
#define QSPI_AR_OFFSET  0x18u
#define QSPI_AR_RESET   0x00000000u

// ABR: Alternate Bytes Register
#define QSPI_ABR_OFFSET  0x1Cu
#define QSPI_ABR_RESET   0x00000000u

// DR: Data Register (FIFO port)
#define QSPI_DR_OFFSET  0x20u

// WCCR: Write Communication Configuration Register (frame format for memory-mapped WRITES)
#define QSPI_WCCR_OFFSET  0x24u
#define QSPI_WCCR_RESET   0x00000000u
// Field layout identical to CCR: use the QSPI_CCR_* field macros.

// Lane mode of a frame phase (CCR/WCCR *MODE fields)
#define QSPI_PH_SKIP  0u  // phase skipped
#define QSPI_PH_SINGLE  1u  // 1 lane
#define QSPI_PH_DUAL  2u  // 2 lanes
#define QSPI_PH_QUAD  3u  // 4 lanes

// Functional mode (CCR.FMODE)
#define QSPI_FM_IND_WRITE  0u  // indirect write
#define QSPI_FM_IND_READ  1u  // indirect read
#define QSPI_FM_MEMMAP  3u  // memory-mapped

#endif // QSPI_REGS_H
