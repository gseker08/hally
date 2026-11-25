using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class ChildAsks : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "ask_presets_edited",
                table: "families",
                type: "boolean",
                nullable: false,
                defaultValue: false);

            migrationBuilder.CreateTable(
                name: "ask_presets",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    order = table.Column<int>(type: "integer", nullable: false),
                    emoji = table.Column<string>(type: "character varying(8)", maxLength: 8, nullable: false),
                    title = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: false),
                    question = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: true),
                    options_json = table.Column<string>(type: "jsonb", nullable: false),
                    screen_minutes = table.Column<int>(type: "integer", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_ask_presets", x => x.id);
                    table.ForeignKey(
                        name: "fk_ask_presets_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "child_asks",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    preset_id = table.Column<Guid>(type: "uuid", nullable: true),
                    emoji = table.Column<string>(type: "character varying(8)", maxLength: 8, nullable: false),
                    title = table.Column<string>(type: "character varying(60)", maxLength: 60, nullable: false),
                    detail = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: true),
                    screen_minutes = table.Column<int>(type: "integer", nullable: true),
                    day = table.Column<DateOnly>(type: "date", nullable: false),
                    status = table.Column<string>(type: "character varying(10)", maxLength: 10, nullable: false),
                    answered_by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    answered_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    note = table.Column<string>(type: "character varying(140)", maxLength: 140, nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_child_asks", x => x.id);
                    table.ForeignKey(
                        name: "fk_child_asks_ask_presets_preset_id",
                        column: x => x.preset_id,
                        principalTable: "ask_presets",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                    table.ForeignKey(
                        name: "fk_child_asks_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_child_asks_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_child_asks_users_answered_by_user_id",
                        column: x => x.answered_by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateIndex(
                name: "ix_ask_presets_family_id_order",
                table: "ask_presets",
                columns: new[] { "family_id", "order" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_child_asks_answered_by_user_id",
                table: "child_asks",
                column: "answered_by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_child_asks_child_id_day",
                table: "child_asks",
                columns: new[] { "child_id", "day" });

            migrationBuilder.CreateIndex(
                name: "ix_child_asks_family_id_day",
                table: "child_asks",
                columns: new[] { "family_id", "day" });

            migrationBuilder.CreateIndex(
                name: "ix_child_asks_preset_id",
                table: "child_asks",
                column: "preset_id");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "child_asks");

            migrationBuilder.DropTable(
                name: "ask_presets");

            migrationBuilder.DropColumn(
                name: "ask_presets_edited",
                table: "families");
        }
    }
}
