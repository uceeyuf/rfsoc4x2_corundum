// SPDX-License-Identifier: BSD-2-Clause-Views
// Copyright (c) 2026 Yijie Yu
//
// udp_echo - send every UDP datagram back to its sender. Runs on the board for
// host/udp_loopback_viewer.py. One thread per port, batched with recvmmsg/sendmmsg,
// each thread moving to the CPU that receives its port's packets (SO_INCOMING_CPU).
// UDP GRO hands back-to-back datagrams of a flow over as one buffer, and UDP GSO
// (UDP_SEGMENT) sends them back cut at the same size, so the echoed datagrams are
// identical while the per-datagram syscall and stack work is shared.
//
// Build on the board:  gcc -O2 -pthread -o udp_echo udp_echo.c
// Run:                 ./udp_echo [base_port] [ports]      (default 1234 4)

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef SOL_UDP
#define SOL_UDP 17
#endif
#ifndef UDP_SEGMENT
#define UDP_SEGMENT 103
#endif
#ifndef UDP_GRO
#define UDP_GRO 104
#endif

#define BATCH  16
#define MAXBUF 65536            // one GRO-coalesced receive
#define CTRL   CMSG_SPACE(sizeof(int))

struct worker {
	pthread_t thread;
	int port, cpu, gro;
	volatile unsigned long long pkts, msgs, bytes, send_err;
};

static void set_buf(int fd, int opt_force, int opt, int size)
{
	// the *FORCE variants ignore net.core.[rw]mem_max but need CAP_NET_ADMIN
	if (setsockopt(fd, SOL_SOCKET, opt_force, &size, sizeof(size)) < 0)
		setsockopt(fd, SOL_SOCKET, opt, &size, sizeof(size));
}

static void *run(void *arg)
{
	struct worker *w = arg;
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(w->cpu, &set);
	pthread_setaffinity_np(pthread_self(), sizeof(set), &set);

	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		perror("socket");
		exit(1);
	}
	set_buf(fd, SO_RCVBUFFORCE, SO_RCVBUF, 32 << 20);
	set_buf(fd, SO_SNDBUFFORCE, SO_SNDBUF, 32 << 20);
	struct sockaddr_in addr = {
		.sin_family = AF_INET,
		.sin_port = htons(w->port),
		.sin_addr.s_addr = htonl(INADDR_ANY),
	};
	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		fprintf(stderr, "bind port %d: %s\n", w->port, strerror(errno));
		exit(1);
	}

	int one = 1;
	w->gro = setsockopt(fd, SOL_UDP, UDP_GRO, &one, sizeof(one)) == 0;

	char (*buf)[MAXBUF] = malloc(BATCH * MAXBUF);
	union { char c[CTRL]; struct cmsghdr align; } ctl[BATCH];
	struct mmsghdr msgs[BATCH];
	struct iovec iov[BATCH];
	struct sockaddr_in from[BATCH];
	unsigned long batches = 0;
	if (!buf) {
		perror("malloc");
		exit(1);
	}

	for (;;) {
		for (int i = 0; i < BATCH; i++) {
			iov[i].iov_base = buf[i];
			iov[i].iov_len = MAXBUF;
			memset(&msgs[i].msg_hdr, 0, sizeof(msgs[i].msg_hdr));
			msgs[i].msg_hdr.msg_iov = &iov[i];
			msgs[i].msg_hdr.msg_iovlen = 1;
			msgs[i].msg_hdr.msg_name = &from[i];
			msgs[i].msg_hdr.msg_namelen = sizeof(from[i]);
			msgs[i].msg_hdr.msg_control = ctl[i].c;
			msgs[i].msg_hdr.msg_controllen = CTRL;
		}
		int n = recvmmsg(fd, msgs, BATCH, MSG_WAITFORONE, NULL);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			perror("recvmmsg");
			break;
		}
		unsigned long long bytes = 0, dgrams = 0;
		for (int i = 0; i < n; i++) {
			struct msghdr *h = &msgs[i].msg_hdr;
			int len = msgs[i].msg_len, seg = 0;
			for (struct cmsghdr *cm = CMSG_FIRSTHDR(h); cm; cm = CMSG_NXTHDR(h, cm))
				if (cm->cmsg_level == SOL_UDP && cm->cmsg_type == UDP_GRO)
					memcpy(&seg, CMSG_DATA(cm), sizeof(seg));
			iov[i].iov_len = len;
			bytes += len;
			if (seg > 0 && len > seg) {
				// coalesced: send back as datagrams of the same size
				uint16_t s16 = seg;
				struct cmsghdr *cm = &ctl[i].align;
				h->msg_controllen = CMSG_SPACE(sizeof(s16));
				cm->cmsg_level = SOL_UDP;
				cm->cmsg_type = UDP_SEGMENT;
				cm->cmsg_len = CMSG_LEN(sizeof(s16));
				memcpy(CMSG_DATA(cm), &s16, sizeof(s16));
				dgrams += (len + seg - 1) / seg;
			} else {
				h->msg_control = NULL;
				h->msg_controllen = 0;
				dgrams++;
			}
		}
		for (int done = 0; done < n;) {
			int r = sendmmsg(fd, msgs + done, n - done, 0);
			if (r < 0) {
				if (errno == EINTR)
					continue;
				w->send_err += n - done;   // ENOBUFS etc.: drop the rest of the batch
				break;
			}
			done += r;
		}
		w->pkts += dgrams;
		w->msgs += n;
		w->bytes += bytes;

		// Follow RSS: run on the CPU whose receive queue delivers this port's packets,
		// so the softirq and the echo share a core and its cache.
		int in_cpu = -1;
		socklen_t sl = sizeof(in_cpu);
		if ((++batches & 63) == 0 &&
		    getsockopt(fd, SOL_SOCKET, SO_INCOMING_CPU, &in_cpu, &sl) == 0 &&
		    in_cpu >= 0 && in_cpu != w->cpu) {
			w->cpu = in_cpu;
			CPU_ZERO(&set);
			CPU_SET(in_cpu, &set);
			pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
		}
	}
	return NULL;
}

int main(int argc, char **argv)
{
	int base = argc > 1 ? atoi(argv[1]) : 1234;
	int ports = argc > 2 ? atoi(argv[2]) : 4;
	int ncpu = sysconf(_SC_NPROCESSORS_ONLN);
	if (ports < 1 || ports > 64 || base < 1 || base + ports > 65536) {
		fprintf(stderr, "usage: %s [base_port] [ports 1-64]\n", argv[0]);
		return 1;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);

	struct worker *w = calloc(ports, sizeof(*w));
	for (int i = 0; i < ports; i++) {
		w[i].port = base + i;
		w[i].cpu = i % ncpu;
		pthread_create(&w[i].thread, NULL, run, &w[i]);
	}
	sleep(1);
	printf("udp_echo: ports %d-%d, %d threads on %d CPUs, UDP GRO %s\n", base, base + ports - 1,
	       ports, ncpu, w[0].gro ? "on" : "off");

	unsigned long long lp = 0, lm = 0, lb = 0;
	for (;;) {
		sleep(1);
		unsigned long long p = 0, m = 0, b = 0, e = 0;
		for (int i = 0; i < ports; i++) {
			p += w[i].pkts;
			m += w[i].msgs;
			b += w[i].bytes;
			e += w[i].send_err;
		}
		if (p != lp)
			printf("echo %8.1f kpps %8.1f Mbit/s  %4.2f datagrams/recv   total %llu packets, %llu send errors\n",
			       (p - lp) / 1e3, (b - lb) * 8 / 1e6, m > lm ? (double)(p - lp) / (m - lm) : 0.0, p, e);
		lp = p;
		lm = m;
		lb = b;
	}
}
