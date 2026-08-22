// iOS Darwin 模块默认不向 Swift 暴露 kern_control 的类型/宏（sockaddr_ctl、ctl_info、
// CTLIOCGINFO）。本垫片把这组系统头显式纳入一个模块，供 PacketTunnel 的 utun fd 扫描使用。
// CTLIOCGINFO 是 _IOWR 函数式宏，Swift 无法导入函数式宏，故在 C 侧求值成常量再暴露。
#ifndef AERION_SYS_H
#define AERION_SYS_H

#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>

static const unsigned long AERION_CTLIOCGINFO = CTLIOCGINFO;

#endif /* AERION_SYS_H */
