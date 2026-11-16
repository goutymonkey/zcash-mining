// SPDX-License-Identifier: Apache-2.0
// Raw stdin bytes -> actual RTL UART CI; sampled RTL RO -> raw stdout bytes.
// Wall time is intentionally decoupled from the simulated clock. Throughput
// here is simulation throughput and must not be reported as chip frequency.
#include "Vzeq_sim_top.h"
#include "verilated.h"
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#ifndef ZEQ_UART_DIV
#define ZEQ_UART_DIV 8
#endif
static volatile std::sig_atomic_t stopping = 0;
static void on_signal(int) { stopping = 1; }

int main(int argc, char** argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    Vzeq_sim_top top{&context};
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    std::signal(SIGPIPE, SIG_IGN);
    if (fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK) < 0 ||
        fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK) < 0) {
        std::perror("nonblocking bridge descriptors");
        return 2;
    }
    top.clk = 0;
    top.rst_n = 0;
    top.host_tx = 1;
    top.temperature = 60;
    auto tick = [&]() {
        top.clk = 0; top.eval(); context.timeInc(5);
        top.clk = 1; top.eval(); context.timeInc(5);
    };
    for (int i = 0; i < 64; ++i) tick();
    top.rst_n = 1;
    for (int i = 0; i < 64; ++i) tick();

    constexpr size_t capacity = 65536;
    constexpr int divider = ZEQ_UART_DIV;
    std::deque<uint8_t> transmit, receive;
    uint16_t frame = 0;
    int tx_bit = 10, tx_left = 0;
    int rx_bit = -1, rx_left = 0;
    uint8_t rx_byte = 0;
    uint64_t cycles = 0, tx_bytes = 0, rx_bytes = 0;
    bool eof = false;
    int result = 0;
    while (!stopping && !context.gotFinish() && !eof) {
        uint8_t bytes[4096];
        if (transmit.size() <= capacity - sizeof(bytes)) {
            const auto n = read(STDIN_FILENO, bytes, sizeof(bytes));
            if (n > 0) transmit.insert(transmit.end(), bytes, bytes + n);
            else if (n == 0) eof = true;
            else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                std::perror("bridge input"); result = 2; break;
            }
        }
        while (!receive.empty()) {
            size_t size = 0;
            for (const auto byte : receive) {
                bytes[size++] = byte;
                if (size == sizeof(bytes)) break;
            }
            const auto written = write(STDOUT_FILENO, bytes, size);
            if (written > 0) {
                for (ssize_t i = 0; i < written; ++i) receive.pop_front();
            } else if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
                break;
            } else {
                if (errno != EPIPE) { std::perror("bridge output"); result = 2; }
                eof = true; break;
            }
        }
        // Backpressure preserves every byte by pausing virtual time, rather
        // than silently dropping simulator output when the host stops reading.
        if (receive.size() >= capacity - 256) {
            pollfd ready{STDOUT_FILENO, POLLOUT, 0};
            poll(&ready, 1, 1);
            continue;
        }
        if (transmit.empty() && tx_bit == 10 && top.busy_n) {
            pollfd ready{STDIN_FILENO, POLLIN, 0};
            poll(&ready, 1, 1);
        }
        for (int batch = 0; batch < 256 && !stopping; ++batch) {
            if (tx_left == 0) {
                if (tx_bit < 10) ++tx_bit;
                if (tx_bit == 10 && !transmit.empty()) {
                    frame = (uint16_t(1) << 9) | (uint16_t(transmit.front()) << 1);
                    transmit.pop_front();
                    ++tx_bytes;
                    tx_bit = 0;
                }
                top.host_tx = tx_bit < 10 ? ((frame >> tx_bit) & 1) : 1;
                tx_left = divider;
            }
            --tx_left;
            tick();
            ++cycles;
            if (rx_bit == -1) {
                if (!top.host_rx) {
                    rx_bit = 0;
                    rx_byte = 0;
                    rx_left = divider + divider / 2;
                }
            } else if (--rx_left == 0) {
                if (rx_bit < 8) {
                    rx_byte |= uint8_t(top.host_rx) << rx_bit;
                    ++rx_bit;
                    rx_left = divider;
                } else {
                    if (!top.host_rx) {
                        std::fprintf(stderr, "RTL UART stop-bit failure at cycle %llu\n", (unsigned long long)cycles);
                        result = 3;
                        stopping = 1;
                        break;
                    }
                    receive.push_back(rx_byte);
                    ++rx_bytes;
                    rx_bit = -1;
                }
            }
        }
    }
    top.final();
    std::fprintf(stderr, "{\"sim_cycles\":%llu,\"tx_bytes\":%llu,\"rx_bytes\":%llu,\"exit_code\":%d}\n",
                 (unsigned long long)cycles, (unsigned long long)tx_bytes,
                 (unsigned long long)rx_bytes, result);
    return result;
}
