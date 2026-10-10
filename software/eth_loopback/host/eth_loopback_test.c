/*
 * Round-trip connectivity / throughput test for the AUP-ZU3 <-> PmEth link.
 * macOS, Linux and Windows.
 *
 * Build:
 *     macOS/Linux:  make      (needs libpcap; on Linux the libpcap-dev package)
 *     Windows:      install Npcap (npcap.com) and the Npcap SDK, then in an
 *                   MSYS2 "MINGW64" shell with gcc and make installed:
 *                   make NPCAP_SDK=C:/path/to/npcap-sdk
 * Run:
 *     List ethernet devices: ./eth_loopback_test --list. The names to use below should be in the leftmost column. 
 *     Run the loopback test: sudo ./eth_loopback_test <device name> --count <number of packets to send> --rate <packets per second> 
 *     
 *     If your rate is too high, you may drop packets - 1,000 should be reasonable enough. 
 *     
 *     (no sudo needed if on Windows)
 *     
 */

#if defined(_WIN32)
#  include <winsock2.h>                     /* before windows.h */
#  include <windows.h>
#  include <iphlpapi.h>
#endif

#include <errno.h>
#include <inttypes.h>
#include <pcap.h>
#include <pthread.h>                        /* MinGW-w64: winpthreads */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#if defined(_WIN32)
#  include <pthread_time.h>                 /* clock_gettime, nanosleep */
#else
#  include <ifaddrs.h>
#  include <net/if.h>
#  if defined(__APPLE__)
#    include <net/if_dl.h>
#  else
#    include <netpacket/packet.h>
#  endif
#endif

#define ETHERTYPE_MARKET_DATA    0x88B5u   /* server -> FPGA */
#define ETHERTYPE_TRADE_DECISION 0x88B6u   /* FPGA -> server */
#define PAYLOAD_LEN 46                     /* 46 + 14 hdr = 802.3 minimum, no padding */
#define FRAME_LEN   (14 + PAYLOAD_LEN)
#define SEQ_OFFSET  14                     /* sequence number starts the payload */
#define END_OFFSET  (SEQ_OFFSET + (PAYLOAD_LEN + 7) / 8 * 8)  /* echo padded to whole messages */
#define TRAILER_OFFSET (END_OFFSET + 8)
#define REPLY_LEN   (TRAILER_OFFSET + 8)
#define END_HEADER  0x72u                  /* type 7 (END), flags EOE */
#define TRAILER_HEADER 0x62u               /* the trailer's first byte */
#define TICK_NS     2.5                    /* the END's tag/busy unit */

#if !defined(_WIN32)
/* Virtual interfaces -- never the FPGA, and they reject media settings. */
static const char *skip_prefixes[] = {
    "lo", "gif", "stf", "awdl", "llw", "utun", "bridge", "p2p", "ap1",
    "vmenet", "vmnet", "docker", "veth", "virbr", "tun", "tap", "anpi", NULL
};
#endif

struct record {
    uint64_t t_send_ns;
    double   rtt_ms;
    uint8_t  got;
    uint8_t  ok;
    uint8_t  end_ok;
    uint16_t tag;        /* END tag, 2.5 ns ticks: frame available -> last whole message */
};

static struct record *recs;
static uint32_t       n_count;
static uint32_t       n_replied;      /* receiver thread only */
static int            verbose;
static pcap_t        *ph;
static uint32_t       n_runt;        /* replies too short to even carry a seq */
static uint32_t       n_bad_shown;   /* limits the per-mismatch dump */

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* Realtime epoch, to match libpcap's per-packet h->ts. Only used for the RTT
 * endpoints; all pacing and elapsed-time logic stays on CLOCK_MONOTONIC.
 * RTT is therefore "userspace send" -> "kernel captured the reply", which
 * excludes RX thread wakeup and scheduling. It still includes the whole host
 * TX stack, which on a USB adapter is the dominant term. */
static uint64_t now_real_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

#if defined(_WIN32)
/* Windows names adapters by GUID, so judge by Npcap's description instead. */
static const char *skip_descriptions[] = {
    "Loopback", "Virtual", "Hyper-V", "VirtualBox", "VMware", "WAN Miniport",
    "Bluetooth", "Wi-Fi Direct", "TAP-Windows", NULL
};
#endif

static int is_virtual(const char *name, const char *description)
{
#if defined(_WIN32)
    if (strstr(name, "Loopback"))
        return 1;
    for (int i = 0; description && skip_descriptions[i]; i++)
        if (strstr(description, skip_descriptions[i]))
            return 1;
    return 0;
#else
    (void)description;
    for (int i = 0; skip_prefixes[i]; i++)
        if (strncmp(name, skip_prefixes[i], strlen(skip_prefixes[i])) == 0)
            return 1;
    return 0;
#endif
}

static void fill_payload(uint8_t *p, uint32_t seq)
{
    p[0] = (uint8_t)(seq >> 24); p[1] = (uint8_t)(seq >> 16);
    p[2] = (uint8_t)(seq >> 8);  p[3] = (uint8_t)seq;
    for (int i = 0; i < PAYLOAD_LEN - 4; i++)
        p[4 + i] = (uint8_t)(i & 0xFF);
}

/* The FPGA learns the server MAC from our source address and replies to it,
 * so this has to be the interface's real MAC or the replies go nowhere. */
#if defined(_WIN32)
static int get_local_mac(const char *iface, uint8_t mac[6])
{
    /* Npcap names an adapter \Device\NPF_{GUID}; Windows knows it by {GUID}. */
    const char *guid = strchr(iface, '{');
    ULONG len = 16 * 1024;
    IP_ADAPTER_ADDRESSES *addrs = NULL, *a;
    int found = 0;

    if (!guid)
        return 0;
    for (int tries = 0; tries < 3; tries++) {
        ULONG r;
        addrs = malloc(len);
        if (!addrs)
            return 0;
        r = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_ALL_INTERFACES, NULL, addrs, &len);
        if (r == NO_ERROR)
            break;
        free(addrs);
        addrs = NULL;
        if (r != ERROR_BUFFER_OVERFLOW)
            return 0;
    }
    if (!addrs)
        return 0;
    for (a = addrs; a; a = a->Next) {
        if (_stricmp(a->AdapterName, guid) == 0 && a->PhysicalAddressLength == 6) {
            memcpy(mac, a->PhysicalAddress, 6);
            found = 1;
            break;
        }
    }
    free(addrs);
    return found;
}
#else
static int get_local_mac(const char *iface, uint8_t mac[6])
{
    struct ifaddrs *ifap, *ifa;
    int found = 0;

    if (getifaddrs(&ifap) != 0)
        return 0;
    for (ifa = ifap; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || strcmp(ifa->ifa_name, iface) != 0)
            continue;
#if defined(__APPLE__)
        if (ifa->ifa_addr->sa_family == AF_LINK) {
            struct sockaddr_dl *sdl = (struct sockaddr_dl *)ifa->ifa_addr;
            if (sdl->sdl_alen == 6) {
                memcpy(mac, LLADDR(sdl), 6);
                found = 1;
                break;
            }
        }
#else
        if (ifa->ifa_addr->sa_family == AF_PACKET) {
            struct sockaddr_ll *sll = (struct sockaddr_ll *)ifa->ifa_addr;
            if (sll->sll_halen == 6) {
                memcpy(mac, sll->sll_addr, 6);
                found = 1;
                break;
            }
        }
#endif
    }
    freeifaddrs(ifap);
    return found;
}
#endif

#if defined(_WIN32)
/* Windows: accept the full \Device\NPF_{...} name, or any piece of the adapter's
 * description that matches exactly one adapter. Returns a name to free, or NULL. */
static char *resolve_iface(const char *arg)
{
    pcap_if_t *alldevs, *d;
    char errbuf[PCAP_ERRBUF_SIZE];
    char *match = NULL;
    int n = 0;

    if (strncmp(arg, "\\Device\\", 8) == 0)
        return strdup(arg);
    if (pcap_findalldevs(&alldevs, errbuf) != 0) {
        fprintf(stderr, "pcap_findalldevs: %s (is Npcap installed?)\n", errbuf);
        return NULL;
    }
    for (d = alldevs; d; d = d->next) {
        if (d->description && strstr(d->description, arg)) {
            n++;
            if (!match)
                match = strdup(d->name);
        }
    }
    pcap_freealldevs(alldevs);
    if (n != 1) {
        fprintf(stderr, "%s adapter matches '%s': run with --list and use a longer piece of\n"
                        "the description, or the full \\Device\\NPF_{...} name\n",
                n ? "more than one" : "no", arg);
        free(match);
        return NULL;
    }
    return match;
}
#endif

static void list_interfaces(void)
{
    pcap_if_t *alldevs, *d;
    char errbuf[PCAP_ERRBUF_SIZE];

    if (pcap_findalldevs(&alldevs, errbuf) != 0) {
        fprintf(stderr, "pcap_findalldevs: %s\n", errbuf);
        return;
    }
    printf("%-12s %-8s %-18s %s\n", "interface", "virtual?", "MAC", "description / note");
    printf("--------------------------------------------------------------------\n");
    for (d = alldevs; d; d = d->next) {
        uint8_t mac[6];
        int have = get_local_mac(d->name, mac);
        int virt = is_virtual(d->name, d->description);
        char macs[24] = "-";
        if (have)
            snprintf(macs, sizeof macs, "%02x:%02x:%02x:%02x:%02x:%02x",
                     mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
        printf("%-12s %-8s %-18s %s%s\n", d->name, virt ? "yes" : "no", macs,
               d->description ? d->description : "",
               virt ? (d->description ? " (skip - no PHY behind it)" : "skip - no PHY behind it") : "");
    }
    pcap_freealldevs(alldevs);
    printf("\nThe FPGA's interface is a real (non-virtual) Ethernet port with carrier\n"
           "but no IP address -- nothing on the far end runs DHCP.\n");
#if defined(__APPLE__)
    printf("Map names to physical ports with: networksetup -listallhardwareports\n");
#elif defined(_WIN32)
    printf("On Windows, pass any unique piece of the description (e.g. \"Realtek USB\")\n"
           "or the full \\Device\\NPF_{...} name.\n");
#endif
}

static void on_packet(u_char *user, const struct pcap_pkthdr *h, const u_char *bytes)
{
    (void)user;
    if (h->caplen < REPLY_LEN) {
        /* Short reply. Counted separately: a runt is a genuine FPGA-side
         * framing fault, not a lost packet, and must not look like one. */
        n_runt++;
        if (n_bad_shown < 5) {
            n_bad_shown++;
            printf("RUNT REPLY: %u bytes captured, expected %u\n",
                   h->caplen, (unsigned)REPLY_LEN);
        }
        return;
    }
    uint32_t seq = ((uint32_t)bytes[SEQ_OFFSET] << 24) |
                   ((uint32_t)bytes[SEQ_OFFSET + 1] << 16) |
                   ((uint32_t)bytes[SEQ_OFFSET + 2] << 8) |
                   ((uint32_t)bytes[SEQ_OFFSET + 3]);
    if (seq >= n_count || recs[seq].got)
        return;

    /* Expected payload for THIS sequence number, rebuilt here. Comparing
     * against one pre-built template is wrong: the first four payload bytes
     * are the sequence number and differ for every frame. */
    uint8_t want[PAYLOAD_LEN];
    fill_payload(want, seq);

    /* Kernel capture time, not callback-run time: the latter folds thread
     * wakeup and scheduler delay into every measurement. */
    uint64_t t_rx = (uint64_t)h->ts.tv_sec * 1000000000ull
                  + (uint64_t)h->ts.tv_usec * 1000ull;
    int64_t  d    = (int64_t)(t_rx - recs[seq].t_send_ns);
    recs[seq].rtt_ms = d > 0 ? (double)d / 1e6 : 0.0;
    recs[seq].ok = (memcmp(bytes + SEQ_OFFSET, want, PAYLOAD_LEN) == 0);
    const u_char *end = bytes + END_OFFSET;
    const u_char *trailer = bytes + TRAILER_OFFSET;
    recs[seq].end_ok = end[0] == END_HEADER && end[2] == (PAYLOAD_LEN + 7) / 8 && end[3] == 0 &&
                       trailer[0] == TRAILER_HEADER && trailer[1] == end[1];
    recs[seq].tag = (uint16_t)((end[4] << 8) | end[5]);
    recs[seq].got = 1;
    if (!recs[seq].end_ok && n_bad_shown < 5) {
        n_bad_shown++;
        printf("BAD END seq=%u: header %02x (want %02x) n_orders %u (want %u) status %02x (want 00), trailer %02x\n",
               seq, end[0], END_HEADER, end[2], (unsigned)((PAYLOAD_LEN + 7) / 8), end[3], trailer[0]);
    }
    n_replied++;

    if (!recs[seq].ok && n_bad_shown < 5) {
        n_bad_shown++;
        printf("PAYLOAD MISMATCH seq=%u caplen=%u\n", seq, h->caplen);
        for (int i = 0; i < PAYLOAD_LEN; i++)
            if (bytes[SEQ_OFFSET + i] != want[i])
                printf("    byte %2d: got %02x want %02x\n",
                       i, bytes[SEQ_OFFSET + i], want[i]);
    }

    if (verbose)
        printf("seq=%u rtt=%.3f ms tag=%.1f ns %s\n", seq, recs[seq].rtt_ms, recs[seq].tag * TICK_NS,
               recs[seq].ok ? "OK" : "PAYLOAD MISMATCH");
}

static void *rx_thread(void *arg)
{
    (void)arg;
    pcap_loop(ph, -1, on_packet, NULL);
    return NULL;
}

static void usage(const char *p)
{
    fprintf(stderr,
        "usage: %s <iface> [--count N] [--rate PPS | --interval SEC] [--grace SEC] [--verbose]\n"
        "       %s --list\n", p, p);
}

int main(int argc, char **argv)
{
    const char *iface = NULL;
    uint32_t count = 20;
    double interval = 0.5, grace = 2.0;
    char errbuf[PCAP_ERRBUF_SIZE];

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--list"))          { list_interfaces(); return 0; }
        else if (!strcmp(argv[i], "--count")    && i + 1 < argc) count    = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--rate")     && i + 1 < argc) interval = 1.0 / atof(argv[++i]);
        else if (!strcmp(argv[i], "--interval") && i + 1 < argc) interval = atof(argv[++i]);
        else if (!strcmp(argv[i], "--grace")    && i + 1 < argc) grace    = atof(argv[++i]);
        else if (!strcmp(argv[i], "--verbose"))  verbose = 1;
        else if (argv[i][0] == '-')              { usage(argv[0]); return 2; }
        else                                     iface = argv[i];
    }
    if (!iface) { usage(argv[0]); return 2; }

#if defined(_WIN32)
    char *resolved = resolve_iface(iface);
    if (!resolved)
        return 2;
    iface = resolved;
#endif

    if (is_virtual(iface, NULL)) {
        fprintf(stderr,
            "'%s' is a virtual interface (VM bridge / tunnel / AirDrop), not a physical\n"
            "Ethernet port -- there is no PHY behind it, so nothing reaches the FPGA.\n"
            "Run '%s --list' to find the real one.\n", iface, argv[0]);
        return 2;
    }

    uint8_t src_mac[6];
    if (!get_local_mac(iface, src_mac)) {
        fprintf(stderr, "could not read the MAC address of %s (does it exist?)\n", iface);
        return 2;
    }

    n_count = count;
    recs = calloc(count, sizeof *recs);
    if (!recs) { fprintf(stderr, "out of memory for %u records\n", count); return 1; }

    /* Capture handle. Immediate mode matters on BSD/macOS: without it BPF sits
     * on packets until its buffer fills, which both inflates RTT and loses
     * frames. The large buffer is what stops the kernel dropping replies at
     * rate -- the failure the Python version could not even see. */
    ph = pcap_create(iface, errbuf);
    if (!ph) { fprintf(stderr, "pcap_create: %s\n", errbuf); return 1; }
    pcap_set_snaplen(ph, 128);
    pcap_set_promisc(ph, 1);
    pcap_set_timeout(ph, 10);
    pcap_set_immediate_mode(ph, 1);
    pcap_set_buffer_size(ph, 16 * 1024 * 1024);
    if (pcap_activate(ph) < 0) {
#if defined(_WIN32)
        fprintf(stderr, "pcap_activate: %s\n(run as Administrator? is Npcap installed?)\n", pcap_geterr(ph));
#else
        fprintf(stderr, "pcap_activate: %s\n(are you root?)\n", pcap_geterr(ph));
#endif
        return 1;
    }

    struct bpf_program fp;
    char filter[64];
    snprintf(filter, sizeof filter, "ether proto 0x%04x", ETHERTYPE_TRADE_DECISION);
    if (pcap_compile(ph, &fp, filter, 1, PCAP_NETMASK_UNKNOWN) < 0 ||
        pcap_setfilter(ph, &fp) < 0) {
        fprintf(stderr, "filter: %s\n", pcap_geterr(ph));
        return 1;
    }
    pcap_freecode(&fp);

    /* Template frame, built once and patched per packet. */
    uint8_t frame[FRAME_LEN];
    memset(frame, 0xFF, 6);                       /* dst: broadcast */
    memcpy(frame + 6, src_mac, 6);                /* src: us, so replies come back */
    frame[12] = (uint8_t)(ETHERTYPE_MARKET_DATA >> 8);
    frame[13] = (uint8_t)(ETHERTYPE_MARKET_DATA & 0xFF);
    fill_payload(frame + 14, 0);

    printf("iface %s  src %02x:%02x:%02x:%02x:%02x:%02x  frames %u",
           iface, src_mac[0], src_mac[1], src_mac[2], src_mac[3], src_mac[4], src_mac[5], count);
    if (interval > 0) printf("  target %.0f pkt/s", 1.0 / interval);
    printf("\n");

    /* On-wire cost per frame: preamble+SFD (8) + frame + FCS (4) + IFG (12).
     * Asking for more than this is asking the host to queue, and the RTT you
     * then measure is your own backlog rather than the path. */
    {
        double wire_bytes = (double)FRAME_LEN + 4.0 + 8.0 + 12.0;
        double cap_pps    = 100e6 / (wire_bytes * 8.0);
        if (interval > 0 && (1.0 / interval) > cap_pps)
            printf("WARNING: %.0f pkt/s requested but 100BASE-TX carries at most %.0f pkt/s\n"
                   "         for %u-byte frames. The excess queues in the host, and RTT\n"
                   "         will report that backlog, not the FPGA.\n",
                   1.0 / interval, cap_pps, (unsigned)FRAME_LEN);
    }

    pthread_t rxt;
    if (pthread_create(&rxt, NULL, rx_thread, NULL) != 0) {
        fprintf(stderr, "pthread_create failed\n"); return 1;
    }
    usleep(200000);   /* let the capture attach before the first frame */

    /* Send, paced against absolute deadlines. Sleep while there is real time
     * to give back, spin for the last stretch -- nanosleep granularity is far
     * coarser than the 100 us period a 10k pps run asks for. */
    uint64_t period_ns = (uint64_t)(interval * 1e9);
    uint64_t start = now_ns();
    for (uint32_t seq = 0; seq < count; seq++) {
        fill_payload(frame + 14, seq);
        recs[seq].t_send_ns = now_real_ns();
        if (pcap_inject(ph, frame, FRAME_LEN) < 0) {
            fprintf(stderr, "pcap_inject: %s\n", pcap_geterr(ph));
            break;
        }

        if (period_ns) {
            uint64_t target = start + (uint64_t)(seq + 1) * period_ns;
            for (;;) {
                uint64_t t = now_ns();
                if (t >= target) break;
                uint64_t left = target - t;
                if (left > 1500000ull) {
                    struct timespec ts = { .tv_sec = 0,
                                           .tv_nsec = (long)(left - 1000000ull) };
                    nanosleep(&ts, NULL);
                }
            }
        }
    }
    double elapsed = (double)(now_ns() - start) / 1e9;

    /* Wait for stragglers, measured from the ACTUAL end of sending. */
    uint64_t deadline = now_ns() + (uint64_t)(grace * 1e9);
    while (now_ns() < deadline && n_replied < count)
        usleep(2000);

    struct pcap_stat ps;
    int have_stats = (pcap_stats(ph, &ps) == 0);
    pcap_breakloop(ph);
    pthread_join(rxt, NULL);

    uint32_t missing = 0, bad = 0, bad_end = 0;
    uint32_t tmin = UINT32_MAX, tmax = 0;
    uint64_t tsum = 0;
    double rmin = 1e18, rmax = 0, rsum = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (!recs[i].got) { missing++; continue; }
        if (!recs[i].ok) bad++;
        if (!recs[i].end_ok) bad_end++;
        if (recs[i].tag < tmin) tmin = recs[i].tag;
        if (recs[i].tag > tmax) tmax = recs[i].tag;
        tsum += recs[i].tag;
        if (recs[i].rtt_ms < rmin) rmin = recs[i].rtt_ms;
        if (recs[i].rtt_ms > rmax) rmax = recs[i].rtt_ms;
        rsum += recs[i].rtt_ms;
    }
    uint32_t replied = count - missing;

    printf("\nsent=%u in %.3fs (%.0f pkt/s achieved)\n", count, elapsed,
           elapsed > 0 ? count / elapsed : 0.0);
    printf("replied=%u missing=%u corrupted=%u bad_end=%u runts=%u\n",
           replied, missing, bad, bad_end, n_runt);
    if (replied)
        printf("END tag (ns) min/avg/max = %.1f / %.1f / %.1f\n",
               tmin * TICK_NS, (double)tsum * TICK_NS / replied, tmax * TICK_NS);
    if (replied)
        printf("rtt min/avg/max = %.3f / %.3f / %.3f ms\n", rmin, rsum / replied, rmax);

    /* A queue that is filling makes each successive reply later than the last.
     * A fixed path latency does not. Comparing the first and last replies
     * separates "the link is slow" from "we outran the link". */
    if (replied >= 20) {
        double head = 0, tail = 0;
        int nh = 0, nt = 0;
        for (uint32_t i = 0; i < count && nh < 10; i++)
            if (recs[i].got) { head += recs[i].rtt_ms; nh++; }
        for (uint32_t i = count; i-- > 0 && nt < 10; )
            if (recs[i].got) { tail += recs[i].rtt_ms; nt++; }
        if (nh && nt) {
            head /= nh; tail /= nt;
            printf("rtt first %d = %.3f ms, last %d = %.3f ms\n", nh, head, nt, tail);
            if (tail > 2.0 * head + 0.1)
                printf("  -> RTT climbs with sequence number: the send queue is filling.\n"
                       "     This measures YOUR backlog, not the path. The FPGA holds at\n"
                       "     most 16 KB (~1.31 ms at 100 Mb/s), so anything beyond that is\n"
                       "     host-side. Re-run with --interval 0.05 for true path latency.\n");
        }
    }
    if (have_stats)
        printf("kernel capture drops: ps_drop=%u ps_ifdrop=%u  "
               "(nonzero means the HOST lost replies, not the FPGA)\n",
               ps.ps_drop, ps.ps_ifdrop);

    if (missing)
        printf("\n'missing' only means no reply came back. Check ps_drop above, then the\n"
               "FPGA: at a high --rate, frames the CPU can't keep up with are dropped in\n"
               "its RX buffers. If ps_drop is zero, re-run slower (--rate 1000).\n");
    if (!replied)
        printf("\nNo replies at all:\n"
               "  - eth_loopback running?  load it over the UART with the BIOS, then jal\n"
               "  - LED3 lit?       link_up: the board heard this host (RX works)\n"
               "  - LED0-2 lit?     the CPU's error bits\n"
               "  - on the wire?    sudo tcpdump -i %s ether proto 0x88b5\n", iface);

    pcap_close(ph);
    free(recs);
    return (missing || bad || bad_end || n_runt || !replied) ? 1 : 0;
}
