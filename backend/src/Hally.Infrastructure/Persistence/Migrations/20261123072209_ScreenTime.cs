using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class ScreenTime : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<int>(
                name: "daily_screen_minutes",
                table: "children",
                type: "integer",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "screen_time_sessions",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    started_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    ended_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    started_by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    ended_by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_screen_time_sessions", x => x.id);
                    table.ForeignKey(
                        name: "fk_screen_time_sessions_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_screen_time_sessions_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_screen_time_sessions_users_ended_by_user_id",
                        column: x => x.ended_by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                    table.ForeignKey(
                        name: "fk_screen_time_sessions_users_started_by_user_id",
                        column: x => x.started_by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateIndex(
                name: "ix_screen_time_sessions_child_id_started_at",
                table: "screen_time_sessions",
                columns: new[] { "child_id", "started_at" });

            migrationBuilder.CreateIndex(
                name: "ix_screen_time_sessions_ended_by_user_id",
                table: "screen_time_sessions",
                column: "ended_by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_screen_time_sessions_family_id",
                table: "screen_time_sessions",
                column: "family_id");

            migrationBuilder.CreateIndex(
                name: "ix_screen_time_sessions_open",
                table: "screen_time_sessions",
                column: "ended_at",
                filter: "ended_at IS NULL");

            migrationBuilder.CreateIndex(
                name: "ix_screen_time_sessions_running",
                table: "screen_time_sessions",
                column: "child_id",
                unique: true,
                filter: "ended_at IS NULL");

            migrationBuilder.CreateIndex(
                name: "ix_screen_time_sessions_started_by_user_id",
                table: "screen_time_sessions",
                column: "started_by_user_id");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "screen_time_sessions");

            migrationBuilder.DropColumn(
                name: "daily_screen_minutes",
                table: "children");
        }
    }
}
