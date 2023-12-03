const std = @import("std");
const Writer = std.io.Writer;
const bufferedWriter = std.io.bufferedWriter;

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

const STDIN_FILENO = std.os.linux.STDIN_FILENO;

const GRID_WIDTH = 50;
const GRID_HEIGHT = 20;
const MAX_LENGTH = GRID_WIDTH * GRID_HEIGHT;
const WRAP = true;
const NORM_SPEED = 150;
const BOOST_SPEED = 100;
const BOOST_REPLENISH = 30;

const d = enum { DIR_UP, DIR_DOWN, DIR_LEFT, DIR_RIGHT };

const Point = struct {
    x: i32,
    y: i32,
};

const Player = struct {
    pos: Point,
    direction: d,
    last_direction: d,
    speed: u32,
    boost_left: u32,

    tail: [MAX_LENGTH]?Point,
};

const Game = struct {
    player: Player,
    food: ?Point,
    boost: ?Point,

    score: u32,
    paused: bool,
    quit: bool,
};

var orig_termios: c.struct_termios = undefined;

fn disable_raw_mode() void {
    _ = c.tcsetattr(STDIN_FILENO, c.TCSAFLUSH, &orig_termios);
}

fn enable_raw_mode() void {
    _ = c.tcgetattr(STDIN_FILENO, &orig_termios);

    var raw: c.termios = orig_termios;
    raw.c_iflag &= ~@as(c_uint, (c.ICRNL | c.IXON));
    raw.c_oflag &= ~@as(c_uint, (c.OPOST));
    raw.c_lflag &= ~@as(c_uint, (c.ECHO | c.ICANON | c.IEXTEN | c.ISIG));

    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 0;

    _ = c.tcsetattr(STDIN_FILENO, c.TCSAFLUSH, &raw);
}

fn is_tail(game: Game, x: i32, y: i32) bool {
    var i: usize = 0;
    while (i < game.score) : (i += 1) {
        if (game.player.tail[i]) |tail| {
            if (tail.x == x and tail.y == y)
                return true;
        }
    }
    return false;
}

fn display(game: Game, writer: anytype) !void {
    try writer.print("[score]: {} {s}\r\n", .{ game.score, if (game.paused)
        "(paused)"
    else
        "        " });

    var y: i32 = 0;
    while (y < GRID_HEIGHT) : (y += 1) {
        var x: i32 = 0;
        while (x < GRID_WIDTH) : (x += 1) {
            if (game.player.pos.x == x and game.player.pos.y == y) {
                try writer.print("\x1b[32m#\x1b[39m", .{});
            } else if (is_tail(game, x, y)) {
                try writer.print("\x1b[32m*\x1b[39m", .{});
            } else if (game.food.?.x == x and game.food.?.y == y) {
                try writer.print("\x1b[31m@\x1b[39m", .{});
            } else if (game.boost) |boost| {
                if (boost.x == x and boost.y == y) {
                    try writer.print("\x1b[34mb\x1b[39m", .{});
                } else {
                    try writer.print("·", .{});
                }
            } else {
                try writer.print("·", .{});
            }
        }
        try writer.print("\r\n", .{});
    }
}

fn control(game: *Game, b: u8, a: bool, d_writer: anytype) !void {
    switch (b) {
        'w' => {
            if (game.player.last_direction != d.DIR_DOWN)
                game.player.direction = d.DIR_UP;
        },
        'a' => {
            if (game.player.last_direction != d.DIR_RIGHT)
                game.player.direction = d.DIR_LEFT;
        },
        's' => {
            if (game.player.last_direction != d.DIR_UP)
                game.player.direction = d.DIR_DOWN;
        },
        'd' => {
            if (game.player.last_direction != d.DIR_LEFT)
                game.player.direction = d.DIR_RIGHT;
        },
        'p' => {
            game.paused = !game.paused;
            try reset_cursor(d_writer);
            try display(game.*, d_writer);
        },
        'q' => {
            game.quit = true;
        },
        'A' => {
            if (a == true) {
                if (game.player.last_direction != d.DIR_DOWN)
                    game.player.direction = d.DIR_UP;
            }
        },
        'D' => {
            if (a == true) {
                if (game.player.last_direction != d.DIR_RIGHT)
                    game.player.direction = d.DIR_LEFT;
            }
        },
        'B' => {
            if (a == true) {
                if (game.player.last_direction != d.DIR_UP)
                    game.player.direction = d.DIR_DOWN;
            }
        },
        'C' => {
            if (a == true) {
                if (game.player.last_direction != d.DIR_LEFT)
                    game.player.direction = d.DIR_RIGHT;
            }
        },
        else => {},
    }
}

fn spawn_food(rand: std.rand.Random, game: *Game) void {
    var x: i32 = rand.intRangeLessThan(i32, 0, GRID_WIDTH);
    var y: i32 = rand.intRangeLessThan(i32, 0, GRID_HEIGHT);

    if (!is_tail(game.*, x, y) and (game.player.pos.x != x and game.player.pos.y != y)) {
        game.food = Point{
            .x = x,
            .y = y,
        };
    } else {
        spawn_food(rand, game);
    }
}

fn spawn_boost(rand: std.rand.Random, game: *Game) void {
    var x: i32 = rand.intRangeLessThan(i32, 0, GRID_WIDTH);
    var y: i32 = rand.intRangeLessThan(i32, 0, GRID_HEIGHT);

    if (!is_tail(game.*, x, y) and (game.player.pos.x != x and game.player.pos.y != y)) {
        game.boost = Point{
            .x = x,
            .y = y,
        };
    } else {
        spawn_boost(rand, game);
    }
}

// This needs to remove tail that is above the score
fn append_shift_right(arr: *[MAX_LENGTH]?Point, elem: Point) void {
    var i: usize = arr.len - 1;
    while (i > 0) : (i -= 1) {
        if (!(i - 1 < 0)) {
            arr[i] = arr[i - 1];
        }
    }
    arr[0] = elem;
}

fn wrap(game: *Game) void {
    if (game.player.pos.y < 0)
        game.player.pos.y = GRID_HEIGHT - 1;
    if (game.player.pos.y > GRID_HEIGHT - 1)
        game.player.pos.y = 0;
    if (game.player.pos.x < 0)
        game.player.pos.x = GRID_WIDTH - 1;
    if (game.player.pos.x > GRID_WIDTH - 1)
        game.player.pos.x = 0;
}

fn check_loss(game: Game) bool {
    if (WRAP)
        return is_tail(game, game.player.pos.x, game.player.pos.y);

    return game.player.pos.x < 0 or game.player.pos.x > GRID_WIDTH - 1 or
        game.player.pos.y < 0 or game.player.pos.y > GRID_HEIGHT - 1 or
        is_tail(game, game.player.pos.x, game.player.pos.y);
}

fn check_win(game: Game) bool {
    return game.player.pos.x == game.food.?.x and game.player.pos.y == game.food.?.y and game.score == MAX_LENGTH - 2;
}

fn reset_cursor(writer: anytype) !void {
    try writer.print("\x1B[{}A\x1B[{}D", .{ GRID_HEIGHT + 1, GRID_WIDTH });
}

pub fn main() !void {
    const stdout = std.io.getStdOut();
    var buf = std.io.bufferedWriter(stdout.writer());

    var w = buf.writer();

    var prng = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.os.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    enable_raw_mode();
    defer disable_raw_mode();

    var game = Game{
        .player = Player{
            .pos = Point{
                .x = GRID_WIDTH / 2,
                .y = GRID_HEIGHT / 2,
            },
            .tail = [_]?Point{null} ** MAX_LENGTH,
            .direction = d.DIR_RIGHT,
            .last_direction = d.DIR_LEFT,
            .speed = NORM_SPEED,
            .boost_left = 0,
        },
        .food = null,
        .boost = null,
        .score = 0,
        .paused = true,
        .quit = false,
    };

    spawn_food(rand, &game);
    spawn_boost(rand, &game);

    try display(game, w);
    try buf.flush();

    var timer = try std.time.Timer.start();

    while (!game.quit) {
        var b: u8 = 0;
        _ = c.read(STDIN_FILENO, &b, 1);

        // if start byte for arrow keys read up to identifier
        var a: bool = false;
        if (b == 27) {
            _ = c.read(STDIN_FILENO, &b, 1);
            _ = c.read(STDIN_FILENO, &b, 1);
            a = true;
        }

        try control(&game, b, a, w);
        try buf.flush();

        var elapsed = timer.read();

        if (game.player.boost_left > 0) {
            game.player.speed = BOOST_SPEED;
        } else {
            game.player.speed = NORM_SPEED;
        }

        if (elapsed >= game.player.speed * 1000000) {
            if (!game.paused) {
                append_shift_right(&game.player.tail, Point{ .x = game.player.pos.x, .y = game.player.pos.y });

                switch (game.player.direction) {
                    d.DIR_UP => game.player.pos.y -= 1,
                    d.DIR_LEFT => game.player.pos.x -= 1,
                    d.DIR_DOWN => game.player.pos.y += 1,
                    d.DIR_RIGHT => game.player.pos.x += 1,
                }
                game.player.last_direction = game.player.direction;

                if (WRAP)
                    wrap(&game);

                if (check_win(game)) {
                    game.quit = true;
                    try w.print("you won!\r\nyour score was {}\r\npress 'q' to quit\r\n", .{game.score});
                } else if (check_loss(game)) {
                    game.quit = true;
                    try w.print("gameover!\r\nyour score was {}\r\npress 'q' to quit\r\n", .{game.score});
                } else if (game.player.pos.x == game.food.?.x and game.player.pos.y == game.food.?.y) {
                    spawn_food(rand, &game);
                    game.score += 1;
                } else if (game.boost) |boost| {
                    if (game.player.pos.x == boost.x and game.player.pos.y == boost.y) {
                        game.boost = null;
                        game.player.boost_left = BOOST_REPLENISH;
                    }
                }
            }

            if (game.boost == null) {
                if (rand.float(f32) <= 0.01) {
                    spawn_boost(rand, &game);
                }
            }

            if (game.player.boost_left > 0) {
                game.player.boost_left -= 1;
            }

            if (!game.quit) {
                try reset_cursor(w);
                try display(game, w);
                try buf.flush();

                timer.reset();
            }
        }

        // To prevent 100% cpu usage
        std.time.sleep(1 * 1000000);
    }

    try buf.flush();
}
