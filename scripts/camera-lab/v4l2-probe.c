/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Disposable camera lab only; never opens a physical camera. */
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <linux/videodev2.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[1], "caps") && strcmp(argv[1], "claim"))) return 2;
    int fd = open(argv[2], O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) { perror("open"); return 1; }
    struct v4l2_capability cap = {0};
    if (ioctl(fd, VIDIOC_QUERYCAP, &cap) || strcmp((char *)cap.driver, "v4l2 loopback")) {
        fprintf(stderr, "Not a v4l2loopback device\n"); close(fd); return 1;
    }
    unsigned flags = cap.capabilities & V4L2_CAP_DEVICE_CAPS ? cap.device_caps : cap.capabilities;
    if (!strcmp(argv[1], "caps")) {
        printf("{\"capture\":%s,\"output\":%s}\n",
            flags & V4L2_CAP_VIDEO_CAPTURE ? "true" : "false",
            flags & V4L2_CAP_VIDEO_OUTPUT ? "true" : "false");
    } else {
        struct v4l2_format fmt = {0};
        fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
        fmt.fmt.pix.width = 1280; fmt.fmt.pix.height = 720;
        fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
        fmt.fmt.pix.field = V4L2_FIELD_NONE;
        int status = ioctl(fd, VIDIOC_S_FMT, &fmt);
        int error = errno;
        /* exclusive_caps removes OUTPUT while owned; S_FMT then returns EINVAL.
         * The harness first proves the same format can be claimed while free. */
        int rejected = status < 0 && (error == EBUSY ||
            (error == EINVAL && !(flags & V4L2_CAP_VIDEO_OUTPUT)));
        printf("{\"claimAccepted\":%s,\"secondProducerRejected\":%s,\"errno\":%d}\n",
            status == 0 ? "true" : "false", rejected ? "true" : "false", status < 0 ? error : 0);
    }
    close(fd); return 0;
}
