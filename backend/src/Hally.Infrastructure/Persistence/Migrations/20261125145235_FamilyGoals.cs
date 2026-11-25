using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class FamilyGoals : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "family_goals",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    week_start = table.Column<DateOnly>(type: "date", nullable: false),
                    reward_title = table.Column<string>(type: "character varying(60)", maxLength: 60, nullable: false),
                    reward_emoji = table.Column<string>(type: "character varying(8)", maxLength: 8, nullable: false),
                    target = table.Column<int>(type: "integer", nullable: false),
                    repeat = table.Column<bool>(type: "boolean", nullable: false),
                    by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    reached_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_family_goals", x => x.id);
                    table.ForeignKey(
                        name: "fk_family_goals_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_family_goals_users_by_user_id",
                        column: x => x.by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateIndex(
                name: "ix_family_goals_by_user_id",
                table: "family_goals",
                column: "by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_family_goals_family_id_week_start",
                table: "family_goals",
                columns: new[] { "family_id", "week_start" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_family_goals_week_start",
                table: "family_goals",
                column: "week_start");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "family_goals");
        }
    }
}
