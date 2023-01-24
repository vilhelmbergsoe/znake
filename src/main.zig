const std = @import("std");
const Writer = std.fs.File.Writer;

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

const STDIN_FILENO = std.os.linux.STDIN_FILENO;

const GRID_WIDTH = 20;
const GRID_HEIGHT = 10;
const MAX_LENGTH = GRID_WIDTH * GRID_HEIGHT;
const WRAP = true;

const fps = 2;

const Dir = enum { DIR_UP, DIR_DOWN, DIR_LEFT, DIR_RIGHT };

const Point = struct {
    x: i32,
    y: i32,
};

const Player = struct {
    pos: Point,
    direction: Dir,
    last_direction: Dir,

    tail: [MAX_LENGTH]?Point,
};

const Game = struct {
    player: Player,
    food: ?Point,

    score: i32,
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
    raw.c_iflag &= ~@intCast(c_uint, (c.ICRNL | c.IXON));
    raw.c_oflag &= ~@intCast(c_uint, (c.OPOST));
    raw.c_lflag &= ~@intCast(c_uint, (c.ECHO | c.ICANON | c.IEXTEN | c.ISIG));

    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 0;

    _ = c.tcsetattr(STDIN_FILENO, c.TCSAFLUSH, &raw);
}

fn istail(game: Game, x: i32, y: i32) bool {
    var i: usize = 0;
    while (i <= game.score) : (i += 1) {
        if (game.player.tail[i]) |tail| {
            if (tail.x == x and tail.y == y)
                return true;
        }
    }
    return false;
}

fn display(game: Game, out: Writer) !void {
    try out.print("[score]: {} {s}\r\n", .{ game.score, if (game.paused)
        "(paused)"
    else
        "        " });

    var y: i32 = 0;
    while (y < GRID_HEIGHT) : (y += 1) {
        var x: i32 = 0;
        while (x < GRID_WIDTH) : (x += 1) {
            if (game.player.pos.x == x and game.player.pos.y == y) {
                try out.print("#", .{});
            } else if (istail(game, x, y)) {
                try out.print("*", .{});
            } else if (game.food) |food| {
                if (food.x == x and food.y == y) {
                    try out.print("@", .{});
                } else {
                    try out.print(".", .{});
                }
            }
        }
        try out.print("\r\n", .{});
    }
}

fn control(game: *Game, b: u8) void {
    switch (b) {
        'w' => {
            if (game.player.last_direction != Dir.DIR_DOWN)
                game.player.direction = Dir.DIR_UP;
        },
        'a' => {
            if (game.player.last_direction != Dir.DIR_RIGHT)
                game.player.direction = Dir.DIR_LEFT;
        },
        's' => {
            if (game.player.last_direction != Dir.DIR_UP)
                game.player.direction = Dir.DIR_DOWN;
        },
        'd' => {
            if (game.player.last_direction != Dir.DIR_LEFT)
                game.player.direction = Dir.DIR_RIGHT;
        },
        'p' => {
            game.paused = !game.paused;
        },
        'q' => {
            game.quit = true;
        },
        else => {},
    }
}

fn spawn_food(rand: std.rand.Random, game: *Game) void {
    var x: i32 = rand.intRangeLessThan(i32, 0, GRID_WIDTH);
    var y: i32 = rand.intRangeLessThan(i32, 0, GRID_HEIGHT);

    if (!istail(game.*, x, y) or (game.player.pos.x == x and game.player.pos.y == y)) {
        game.food = Point{
            .x = x,
            .y = y,
        };
    } else {
        spawn_food(rand, game);
    }
}

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
        return istail(game, game.player.pos.x, game.player.pos.y);

    return game.player.pos.x < 0 or game.player.pos.x > GRID_WIDTH - 1 or
        game.player.pos.y < 0 or game.player.pos.y > GRID_WIDTH - 1 or
        istail(game, game.player.pos.x, game.player.pos.y);
}

fn check_win(game: Game) bool {
    if (game.food) |food| {
        return game.player.pos.x == food.x and game.player.pos.y == food.y and game.score == MAX_LENGTH - 2;
    }
    return false;
}

fn reset_cursor(out: Writer) !void {
    try out.print("\x1B[{}A\x1B[{}D", .{ GRID_HEIGHT + 1, GRID_WIDTH });
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

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
            .direction = Dir.DIR_RIGHT,
            .last_direction = Dir.DIR_LEFT,
        },
        .food = null,
        .score = 0,
        .paused = true,
        .quit = false,
    };

    spawn_food(rand, &game);

    try display(game, stdout);

    var timer = try std.time.Timer.start();

    while (!game.quit) {
        var b: u8 = 0;
        _ = c.read(STDIN_FILENO, &b, 1);
        control(&game, b);

        var elapsed = timer.read();

        if (elapsed >= 200 * 1000000) {
            if (!game.paused) {
                switch (game.player.direction) {
                    Dir.DIR_UP => game.player.pos.y -= 1,
                    Dir.DIR_LEFT => game.player.pos.x -= 1,
                    Dir.DIR_DOWN => game.player.pos.y += 1,
                    Dir.DIR_RIGHT => game.player.pos.x += 1,
                }
                game.player.last_direction = game.player.direction;

                if (WRAP)
                    wrap(&game);

                if (check_loss(game)) {
                    game.quit = true;
                    try stdout.print("gameover!\r\nyour score was {}\r\npress 'q' to quit\r\n", .{game.score});
                } else if (check_win(game)) {
                    game.quit = true;
                    try stdout.print("you won!\r\nyour score was {}\r\npress 'q' to quit\r\n", .{game.score});
                } else {
                    append_shift_right(&game.player.tail, Point{ .x = game.player.pos.x, .y = game.player.pos.y });
                    if (game.food) |food| {
                        if (game.player.pos.x == food.x and game.player.pos.y == food.y) {
                            game.score += 1;
                            spawn_food(rand, &game);
                        }
                    }

                    try reset_cursor(stdout);
                    try display(game, stdout);

                    timer.reset();
                }
            } else {
                    try reset_cursor(stdout);
                    try display(game, stdout);

                    timer.reset();
            }
        }
    }
}
