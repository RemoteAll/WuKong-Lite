//! D13x demo88-nor 板级常量（与官方 defconfig 对齐）。
pub const name = "d13x demo88-nor";

pub const panel = struct {
    pub const width = 1024;
    pub const height = 600;
    pub const enable_gpio = "PE.13";
};

pub const touch = struct {
    pub const name = "gt911";
    pub const i2c = "i2c2";
    pub const reset_gpio = "PA.10";
    pub const int_gpio = "PA.11";
};
