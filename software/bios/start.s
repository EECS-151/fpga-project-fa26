.section    .start
.global     _start

_start:
    li      sp, 0x1001fff0
    jal     main
