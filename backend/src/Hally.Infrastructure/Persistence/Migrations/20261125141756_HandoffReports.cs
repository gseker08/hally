using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class HandoffReports : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "handoff_reports",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    by_user_id = table.Column<Guid>(type: "uuid", nullable: false),
                    day = table.Column<DateOnly>(type: "date", nullable: false),
                    summary_json = table.Column<string>(type: "jsonb", nullable: false),
                    incidents = table.Column<int[]>(type: "integer[]", nullable: false),
                    note = table.Column<string>(type: "character varying(500)", maxLength: 500, nullable: true),
                    photo_key = table.Column<string>(type: "character varying(120)", maxLength: 120, nullable: true),
                    photo_content_type = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: true),
                    sent_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    thanked_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    thanked_by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_handoff_reports", x => x.id);
                    table.ForeignKey(
                        name: "fk_handoff_reports_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_handoff_reports_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_handoff_reports_users_by_user_id",
                        column: x => x.by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_handoff_reports_users_thanked_by_user_id",
                        column: x => x.thanked_by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateIndex(
                name: "ix_handoff_reports_by_user_id",
                table: "handoff_reports",
                column: "by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_handoff_reports_child_id_day_by_user_id",
                table: "handoff_reports",
                columns: new[] { "child_id", "day", "by_user_id" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_handoff_reports_family_id_day",
                table: "handoff_reports",
                columns: new[] { "family_id", "day" });

            migrationBuilder.CreateIndex(
                name: "ix_handoff_reports_thanked_by_user_id",
                table: "handoff_reports",
                column: "thanked_by_user_id");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "handoff_reports");
        }
    }
}
