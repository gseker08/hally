using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class ChildMode : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<int>(
                name: "screen_minutes",
                table: "rewards",
                type: "integer",
                nullable: true);

            migrationBuilder.AddColumn<Guid>(
                name: "habit_id",
                table: "point_entries",
                type: "uuid",
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "require_child_approval",
                table: "families",
                type: "boolean",
                nullable: false,
                defaultValue: true);

            migrationBuilder.CreateTable(
                name: "child_claims",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    kind = table.Column<string>(type: "character varying(10)", maxLength: 10, nullable: false),
                    item_id = table.Column<Guid>(type: "uuid", nullable: false),
                    title = table.Column<string>(type: "character varying(60)", maxLength: 60, nullable: false),
                    points = table.Column<int>(type: "integer", nullable: false),
                    day = table.Column<DateOnly>(type: "date", nullable: false),
                    status = table.Column<string>(type: "character varying(10)", maxLength: 10, nullable: false),
                    decided_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    decided_by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_child_claims", x => x.id);
                    table.ForeignKey(
                        name: "fk_child_claims_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_child_claims_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_child_claims_users_decided_by_user_id",
                        column: x => x.decided_by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateTable(
                name: "child_devices",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    token_hash = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    name = table.Column<string>(type: "character varying(60)", maxLength: 60, nullable: true),
                    last_seen_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    revoked_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_child_devices", x => x.id);
                    table.ForeignKey(
                        name: "fk_child_devices_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_child_devices_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "pairing_codes",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    created_by_user_id = table.Column<Guid>(type: "uuid", nullable: false),
                    code_hash = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    expires_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    used_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_pairing_codes", x => x.id);
                    table.ForeignKey(
                        name: "fk_pairing_codes_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_pairing_codes_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_pairing_codes_users_created_by_user_id",
                        column: x => x.created_by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "screen_bonuses",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    day = table.Column<DateOnly>(type: "date", nullable: false),
                    minutes = table.Column<int>(type: "integer", nullable: false),
                    source = table.Column<string>(type: "character varying(10)", maxLength: 10, nullable: false),
                    by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_screen_bonuses", x => x.id);
                    table.ForeignKey(
                        name: "fk_screen_bonuses_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_screen_bonuses_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_screen_bonuses_users_by_user_id",
                        column: x => x.by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateTable(
                name: "screen_usages",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    day = table.Column<DateOnly>(type: "date", nullable: false),
                    seconds = table.Column<int>(type: "integer", nullable: false),
                    updated_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_screen_usages", x => x.id);
                    table.ForeignKey(
                        name: "fk_screen_usages_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_screen_usages_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "ix_point_entries_bonus_day",
                table: "point_entries",
                columns: new[] { "child_id", "day" },
                unique: true,
                filter: "kind = 'Bonus'");

            migrationBuilder.CreateIndex(
                name: "ix_point_entries_habit_day",
                table: "point_entries",
                columns: new[] { "habit_id", "day" },
                unique: true,
                filter: "habit_id IS NOT NULL");

            migrationBuilder.CreateIndex(
                name: "ix_child_claims_decided_by_user_id",
                table: "child_claims",
                column: "decided_by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_child_claims_family_id_status",
                table: "child_claims",
                columns: new[] { "family_id", "status" });

            migrationBuilder.CreateIndex(
                name: "ix_child_claims_item_day",
                table: "child_claims",
                columns: new[] { "child_id", "item_id", "day" },
                unique: true,
                filter: "status <> 'Rejected'");

            migrationBuilder.CreateIndex(
                name: "ix_child_devices_child_id",
                table: "child_devices",
                column: "child_id");

            migrationBuilder.CreateIndex(
                name: "ix_child_devices_family_id",
                table: "child_devices",
                column: "family_id");

            migrationBuilder.CreateIndex(
                name: "ix_child_devices_token_hash",
                table: "child_devices",
                column: "token_hash",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_pairing_codes_child_id",
                table: "pairing_codes",
                column: "child_id");

            migrationBuilder.CreateIndex(
                name: "ix_pairing_codes_code_hash",
                table: "pairing_codes",
                column: "code_hash");

            migrationBuilder.CreateIndex(
                name: "ix_pairing_codes_created_by_user_id",
                table: "pairing_codes",
                column: "created_by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_pairing_codes_family_id",
                table: "pairing_codes",
                column: "family_id");

            migrationBuilder.CreateIndex(
                name: "ix_screen_bonuses_by_user_id",
                table: "screen_bonuses",
                column: "by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_screen_bonuses_child_id_day",
                table: "screen_bonuses",
                columns: new[] { "child_id", "day" });

            migrationBuilder.CreateIndex(
                name: "ix_screen_bonuses_family_id",
                table: "screen_bonuses",
                column: "family_id");

            migrationBuilder.CreateIndex(
                name: "ix_screen_usages_child_id_day",
                table: "screen_usages",
                columns: new[] { "child_id", "day" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_screen_usages_family_id",
                table: "screen_usages",
                column: "family_id");

            migrationBuilder.AddForeignKey(
                name: "fk_point_entries_habits_habit_id",
                table: "point_entries",
                column: "habit_id",
                principalTable: "habits",
                principalColumn: "id",
                onDelete: ReferentialAction.SetNull);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "fk_point_entries_habits_habit_id",
                table: "point_entries");

            migrationBuilder.DropTable(
                name: "child_claims");

            migrationBuilder.DropTable(
                name: "child_devices");

            migrationBuilder.DropTable(
                name: "pairing_codes");

            migrationBuilder.DropTable(
                name: "screen_bonuses");

            migrationBuilder.DropTable(
                name: "screen_usages");

            migrationBuilder.DropIndex(
                name: "ix_point_entries_bonus_day",
                table: "point_entries");

            migrationBuilder.DropIndex(
                name: "ix_point_entries_habit_day",
                table: "point_entries");

            migrationBuilder.DropColumn(
                name: "screen_minutes",
                table: "rewards");

            migrationBuilder.DropColumn(
                name: "habit_id",
                table: "point_entries");

            migrationBuilder.DropColumn(
                name: "require_child_approval",
                table: "families");
        }
    }
}
