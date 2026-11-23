using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class ChoreStars : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "chores",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    title = table.Column<string>(type: "character varying(60)", maxLength: 60, nullable: false),
                    points = table.Column<int>(type: "integer", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_chores", x => x.id);
                    table.ForeignKey(
                        name: "fk_chores_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_chores_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "rewards",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    title = table.Column<string>(type: "character varying(60)", maxLength: 60, nullable: false),
                    cost = table.Column<int>(type: "integer", nullable: false),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_rewards", x => x.id);
                    table.ForeignKey(
                        name: "fk_rewards_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "point_entries",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    kind = table.Column<string>(type: "character varying(10)", maxLength: 10, nullable: false),
                    chore_id = table.Column<Guid>(type: "uuid", nullable: true),
                    reward_id = table.Column<Guid>(type: "uuid", nullable: true),
                    title = table.Column<string>(type: "character varying(60)", maxLength: 60, nullable: false),
                    points = table.Column<int>(type: "integer", nullable: false),
                    day = table.Column<DateOnly>(type: "date", nullable: false),
                    by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_point_entries", x => x.id);
                    table.ForeignKey(
                        name: "fk_point_entries_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_point_entries_chores_chore_id",
                        column: x => x.chore_id,
                        principalTable: "chores",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                    table.ForeignKey(
                        name: "fk_point_entries_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_point_entries_rewards_reward_id",
                        column: x => x.reward_id,
                        principalTable: "rewards",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                    table.ForeignKey(
                        name: "fk_point_entries_users_by_user_id",
                        column: x => x.by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateIndex(
                name: "ix_chores_child_id",
                table: "chores",
                column: "child_id");

            migrationBuilder.CreateIndex(
                name: "ix_chores_family_id",
                table: "chores",
                column: "family_id");

            migrationBuilder.CreateIndex(
                name: "ix_point_entries_by_user_id",
                table: "point_entries",
                column: "by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_point_entries_child_id_created_at",
                table: "point_entries",
                columns: new[] { "child_id", "created_at" });

            migrationBuilder.CreateIndex(
                name: "ix_point_entries_chore_day",
                table: "point_entries",
                columns: new[] { "chore_id", "child_id", "day" },
                unique: true,
                filter: "chore_id IS NOT NULL");

            migrationBuilder.CreateIndex(
                name: "ix_point_entries_family_id",
                table: "point_entries",
                column: "family_id");

            migrationBuilder.CreateIndex(
                name: "ix_point_entries_reward_id",
                table: "point_entries",
                column: "reward_id");

            migrationBuilder.CreateIndex(
                name: "ix_rewards_family_id",
                table: "rewards",
                column: "family_id");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "point_entries");

            migrationBuilder.DropTable(
                name: "chores");

            migrationBuilder.DropTable(
                name: "rewards");
        }
    }
}
