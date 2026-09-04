#ifndef __ICM20608_H
#define __ICM20608_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define ICM20608_IOCTL_BASE	'D'

struct icm20608_data {
	__s16 accel_x;
	__s16 accel_y;
	__s16 accel_z;
	__s16 temp;
	__s16 gyro_x;
	__s16 gyro_y;
	__s16 gyro_z;
};

#define ICM20608_GET_DATA	_IOR(ICM20608_IOCTL_BASE, 0, struct icm20608_data)
#define ICM20608_GET_WHOAMI	_IOR(ICM20608_IOCTL_BASE, 1, unsigned char)

#endif
