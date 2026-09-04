/*
 * SPI driver for InvenSense ICM-20608 6-axis sensor (ALIENTEK ALPHA board)
 *
 * Compatible: "alientek,icm20608"
 * Bus: ECSPI3, CS GPIO, SPI Mode 3
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */

#include <linux/module.h>
#include <linux/fs.h>
#include <linux/spi/spi.h>
#include <linux/of.h>
#include <linux/delay.h>
#include <linux/miscdevice.h>
#include <linux/uaccess.h>
#include <linux/icm20608.h>

#define DEVICE_NAME		"icm20608"

#define ICM20_SMPLRT_DIV	0x19
#define ICM20_CONFIG		0x1A
#define ICM20_GYRO_CONFIG	0x1B
#define ICM20_ACCEL_CONFIG	0x1C
#define ICM20_ACCEL_CONFIG2	0x1D
#define ICM20_PWR_MGMT_1	0x6B
#define ICM20_PWR_MGMT_2	0x6C
#define ICM20_WHO_AM_I		0x75
#define ICM20_ACCEL_XOUT_H	0x3B

#define ICM20608_ID		0xAF
#define ICM20608_READ_FLAG	0x80

struct icm20608 {
	struct miscdevice misc_dev;
	struct spi_device *spi;
};

static struct icm20608 icm20608_dev;

static int icm20608_read_regs(struct spi_device *spi, u8 reg, u8 *buf, u8 len)
{
	u8 tx = reg | ICM20608_READ_FLAG;
	int ret;

	ret = spi_write_then_read(spi, &tx, 1, buf, len);
	if (ret)
		dev_err(&spi->dev, "read reg 0x%02x failed: %d\n", reg, ret);
	return ret;
}

static int icm20608_write_reg(struct spi_device *spi, u8 reg, u8 data)
{
	u8 tx[2] = { reg & 0x7f, data };
	int ret;

	ret = spi_write(spi, tx, sizeof(tx));
	if (ret)
		dev_err(&spi->dev, "write reg 0x%02x failed: %d\n", reg, ret);
	return ret;
}

static int icm20608_read_onereg(struct spi_device *spi, u8 reg, u8 *val)
{
	return icm20608_read_regs(spi, reg, val, 1);
}

static int icm20608_read_sensor(struct spi_device *spi, struct icm20608_data *out)
{
	u8 buf[14];
	int ret;

	ret = icm20608_read_regs(spi, ICM20_ACCEL_XOUT_H, buf, sizeof(buf));
	if (ret)
		return ret;

	out->accel_x = (s16)((buf[0] << 8) | buf[1]);
	out->accel_y = (s16)((buf[2] << 8) | buf[3]);
	out->accel_z = (s16)((buf[4] << 8) | buf[5]);
	out->temp    = (s16)((buf[6] << 8) | buf[7]);
	out->gyro_x  = (s16)((buf[8] << 8) | buf[9]);
	out->gyro_y  = (s16)((buf[10] << 8) | buf[11]);
	out->gyro_z  = (s16)((buf[12] << 8) | buf[13]);
	return 0;
}

static int icm20608_init_hw(struct spi_device *spi)
{
	u8 whoami = 0;
	int ret;

	/* Soft reset */
	ret = icm20608_write_reg(spi, ICM20_PWR_MGMT_1, 0x80);
	if (ret)
		return ret;
	mdelay(50);

	/* Auto select best available clock source */
	ret = icm20608_write_reg(spi, ICM20_PWR_MGMT_1, 0x01);
	if (ret)
		return ret;
	mdelay(10);

	ret = icm20608_read_onereg(spi, ICM20_WHO_AM_I, &whoami);
	if (ret)
		return ret;

	if (whoami != ICM20608_ID) {
		dev_err(&spi->dev, "WHO_AM_I=0x%02x, expect 0x%02x\n",
			whoami, ICM20608_ID);
		return -ENODEV;
	}
	dev_info(&spi->dev, "WHO_AM_I=0x%02x OK\n", whoami);

	/* Enable accel + gyro all axes */
	ret = icm20608_write_reg(spi, ICM20_PWR_MGMT_2, 0x00);
	if (ret)
		return ret;

	/* Sample rate divider: 1kHz / (1+9) = 100Hz */
	ret = icm20608_write_reg(spi, ICM20_SMPLRT_DIV, 0x09);
	if (ret)
		return ret;

	/* DLPF ~20Hz */
	ret = icm20608_write_reg(spi, ICM20_CONFIG, 0x04);
	if (ret)
		return ret;

	/* Gyro ±2000 dps */
	ret = icm20608_write_reg(spi, ICM20_GYRO_CONFIG, 0x18);
	if (ret)
		return ret;

	/* Accel ±2g */
	ret = icm20608_write_reg(spi, ICM20_ACCEL_CONFIG, 0x00);
	if (ret)
		return ret;

	/* Accel DLPF */
	ret = icm20608_write_reg(spi, ICM20_ACCEL_CONFIG2, 0x04);
	if (ret)
		return ret;

	return 0;
}

static int icm20608_open(struct inode *inode, struct file *file)
{
	return 0;
}

static int icm20608_release(struct inode *inode, struct file *file)
{
	return 0;
}

static long icm20608_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct icm20608_data data;
	u8 whoami;
	int ret;

	switch (cmd) {
	case ICM20608_GET_DATA:
		ret = icm20608_read_sensor(icm20608_dev.spi, &data);
		if (ret)
			return ret;
		if (copy_to_user((void __user *)arg, &data, sizeof(data)))
			return -EFAULT;
		return 0;

	case ICM20608_GET_WHOAMI:
		ret = icm20608_read_onereg(icm20608_dev.spi, ICM20_WHO_AM_I, &whoami);
		if (ret)
			return ret;
		if (copy_to_user((void __user *)arg, &whoami, sizeof(whoami)))
			return -EFAULT;
		return 0;

	default:
		return -ENOTTY;
	}
}

static const struct file_operations icm20608_fops = {
	.owner		= THIS_MODULE,
	.open		= icm20608_open,
	.release	= icm20608_release,
	.unlocked_ioctl	= icm20608_ioctl,
};

static ssize_t show_sensor_field(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct icm20608_data data;
	const char *name = attr->attr.name;
	s16 val = 0;

	if (icm20608_read_sensor(icm20608_dev.spi, &data))
		return sprintf(buf, "%d\n", -1);

	if (!strcmp(name, "accel_x"))
		val = data.accel_x;
	else if (!strcmp(name, "accel_y"))
		val = data.accel_y;
	else if (!strcmp(name, "accel_z"))
		val = data.accel_z;
	else if (!strcmp(name, "gyro_x"))
		val = data.gyro_x;
	else if (!strcmp(name, "gyro_y"))
		val = data.gyro_y;
	else if (!strcmp(name, "gyro_z"))
		val = data.gyro_z;
	else if (!strcmp(name, "temp"))
		val = data.temp;

	return sprintf(buf, "%d\n", val);
}

static ssize_t show_whoami(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	u8 whoami = 0;

	if (icm20608_read_onereg(icm20608_dev.spi, ICM20_WHO_AM_I, &whoami))
		return sprintf(buf, "%d\n", -1);

	return sprintf(buf, "0x%02x\n", whoami);
}

static DEVICE_ATTR(accel_x, S_IRUGO, show_sensor_field, NULL);
static DEVICE_ATTR(accel_y, S_IRUGO, show_sensor_field, NULL);
static DEVICE_ATTR(accel_z, S_IRUGO, show_sensor_field, NULL);
static DEVICE_ATTR(gyro_x,  S_IRUGO, show_sensor_field, NULL);
static DEVICE_ATTR(gyro_y,  S_IRUGO, show_sensor_field, NULL);
static DEVICE_ATTR(gyro_z,  S_IRUGO, show_sensor_field, NULL);
static DEVICE_ATTR(temp,    S_IRUGO, show_sensor_field, NULL);
static DEVICE_ATTR(whoami,  S_IRUGO, show_whoami, NULL);

static struct attribute *icm20608_attrs[] = {
	&dev_attr_accel_x.attr,
	&dev_attr_accel_y.attr,
	&dev_attr_accel_z.attr,
	&dev_attr_gyro_x.attr,
	&dev_attr_gyro_y.attr,
	&dev_attr_gyro_z.attr,
	&dev_attr_temp.attr,
	&dev_attr_whoami.attr,
	NULL
};

static const struct attribute_group icm20608_attrs_group = {
	.attrs = icm20608_attrs,
};

static const struct attribute_group *icm20608_attr_groups[] = {
	&icm20608_attrs_group,
	NULL
};

static int icm20608_probe(struct spi_device *spi)
{
	int ret;

	/* Mode 3 if DT did not set it */
	spi->mode |= SPI_MODE_3;
	spi->bits_per_word = 8;
	ret = spi_setup(spi);
	if (ret) {
		dev_err(&spi->dev, "spi_setup failed: %d\n", ret);
		return ret;
	}

	ret = icm20608_init_hw(spi);
	if (ret) {
		dev_err(&spi->dev, "icm20608 init failed\n");
		return ret;
	}

	icm20608_dev.spi = spi;
	icm20608_dev.misc_dev.name = DEVICE_NAME;
	icm20608_dev.misc_dev.minor = MISC_DYNAMIC_MINOR;
	icm20608_dev.misc_dev.fops = &icm20608_fops;
	icm20608_dev.misc_dev.groups = icm20608_attr_groups;

	ret = misc_register(&icm20608_dev.misc_dev);
	if (ret) {
		dev_err(&spi->dev, "misc_register failed: %d\n", ret);
		return ret;
	}

	dev_set_drvdata(icm20608_dev.misc_dev.this_device, &icm20608_dev);
	dev_info(&spi->dev, "icm20608 probe OK, /dev/%s\n", DEVICE_NAME);
	return 0;
}

static int icm20608_remove(struct spi_device *spi)
{
	misc_deregister(&icm20608_dev.misc_dev);
	icm20608_dev.spi = NULL;
	return 0;
}

static const struct of_device_id icm20608_of_match[] = {
	{ .compatible = "alientek,icm20608", },
	{ }
};
MODULE_DEVICE_TABLE(of, icm20608_of_match);

static const struct spi_device_id icm20608_id[] = {
	{ "icm20608", 0 },
	{ }
};
MODULE_DEVICE_TABLE(spi, icm20608_id);

static struct spi_driver icm20608_driver = {
	.driver = {
		.name		= DEVICE_NAME,
		.owner		= THIS_MODULE,
		.of_match_table	= of_match_ptr(icm20608_of_match),
	},
	.probe	= icm20608_probe,
	.remove	= icm20608_remove,
	.id_table = icm20608_id,
};

module_spi_driver(icm20608_driver);

MODULE_AUTHOR("gengtao");
MODULE_DESCRIPTION("ALIENTEK ICM-20608 6-axis SPI sensor driver");
MODULE_LICENSE("GPL");
