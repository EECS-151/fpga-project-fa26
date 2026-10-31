# The CPU's view of the accelerator (hardware/sim/accel_mmio_tb.sv checks the results, and that
# each access below reaches the accelerator exactly once). x20 is the step flag; each step leaves
# its results in x1..x23. x26..x29 hold addresses and x30/x31 are scratch.
.section .start
.global _start

_start:
    li   x28, 0x80010000         # the accelerator's window
    li   x29, 0x80000000         # the UART and Ethernet registers
    li   x27, 0x10000000         # DMEM
    li   x14, -1                 # only the load at step 2 that never runs would change it

    # 1: after reset the log is empty and nothing is set
    lw   x1, 0x010(x28)          # LOG_DATA  = 0 (empty)
    lw   x2, 0x014(x28)          # LOG_COUNT = 0
    lw   x3, 0x000(x28)          # STATUS    = 0
    li   x20, 1

    # 2: the testbench now sends a frame: SESSION_START (600 heartbeats, limits 7/5/42) and two
    #    TRADEs, which the accelerator logs. Each LOG_DATA load pops an entry, so none may be
    #    issued twice or on a path not taken
    li   x31, 3
wait_log:
    lw   x4, 0x014(x28)          # LOG_COUNT until all of them are in: 3
    bne  x4, x31, wait_log
    j    pop
    lw   x14, 0x010(x28)         # never runs: must not pop the log
pop:
    lw   x5, 0x010(x28)          # the session: 0xA0000258
    lw   x6, 0x010(x28)          # TRADE side 0 qty 0x123: 0x90000123, the very next load
    add  x7, x5, x6              # uses both right away: 0x3000037B
    lw   x8, 0x010(x28)          # TRADE side 1 qty 0x45: 0x90010045
    lw   x9, 0x010(x28)          # 0: empty again
    lw   x10, 0x038(x28)         # SESSION_HEARTBEATS = 0x02580258 (remaining, total)
    lw   x11, 0x034(x28)         # SESSION_LIMITS = 0x002A0507
    lw   x12, 0x000(x28)         # STATUS = 0x1: pre-open
    li   x20, 2

    # 3: write the whole shadow bank (65 words at 0x100..0x200, word i = 0xA5C30000 + i), then
    #    COMMIT epoch 0, the heartbeat marker at the session's start: the bank swaps in, and
    #    STATUS shows it a few cycles later
    addi x31, x28, 0x100
    addi x26, x28, 0x204
    li   x30, 0xA5C30000
bank_loop:
    sw   x30, 0(x31)
    addi x30, x30, 1
    addi x31, x31, 4
    bne  x31, x26, bank_loop
    sw   x0, 0x004(x28)          # COMMIT epoch 0
wait_commit:
    lw   x13, 0x000(x28)         # STATUS until [6], the active bank valid: 0x41
    andi x31, x13, 0x40
    beqz x31, wait_commit
    li   x20, 3

    # 4: a COMMIT for any other epoch is stale, and changes nothing else
    li   x30, 7
    sw   x30, 0x004(x28)         # COMMIT epoch 7
wait_stale:
    lw   x15, 0x00C(x28)         # STALE_COMMITS until it counts it: 1
    beqz x15, wait_stale
    lw   x16, 0x000(x28)         # STATUS = 0x41 still (epoch 0)
    lw   x17, 0x008(x28)         # MISSED_COMMITS = 0
    li   x20, 4

    # 5: around the window: DMEM, Ethernet and the UART are not the accelerator, and a load from
    #    them right after an accelerator load gets their data, not the accelerator's
    li   x30, 0x13579BDF
    sw   x30, 0(x27)             # DMEM
    lw   x18, 0x000(x28)         # STATUS = 0x41
    lw   x19, 0(x27)             # DMEM = 0x13579BDF
    lw   x21, 0x000(x28)         # STATUS = 0x41, right after the DMEM load
    lw   x22, 0x020(x29)         # ETH_STATUS = 0 (the CPU's Ethernet port is tied off)
    lw   x23, 0x014(x29)         # UART status (only checked to stay off the accelerator)
    li   x20, 5

done:
    j    done
