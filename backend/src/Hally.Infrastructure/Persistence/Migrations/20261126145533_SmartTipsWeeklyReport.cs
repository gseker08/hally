using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class SmartTipsWeeklyReport : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "tips_enabled",
                table: "family_members",
                type: "boolean",
                nullable: false,
                defaultValue: true);

            migrationBuilder.AddColumn<int>(
                name: "weekly_report_day",
                table: "family_members",
                type: "integer",
                nullable: false,
                defaultValue: 0);

            migrationBuilder.AddColumn<DateOnly>(
                name: "weekly_report_sent_on",
                table: "family_members",
                type: "date",
                nullable: true);

            migrationBuilder.AddColumn<TimeOnly>(
                name: "weekly_report_time",
                table: "family_members",
                type: "time without time zone",
                nullable: true);

            // Existing parents get the Sunday 19:00 report like new ones; caregivers never get it (the job checks the role).
            migrationBuilder.Sql("UPDATE family_members SET weekly_report_time = '19:00' WHERE role IN ('Owner', 'Adult');");

            migrationBuilder.AddColumn<int>(
                name: "screen_goal_restore_minutes",
                table: "children",
                type: "integer",
                nullable: true);

            migrationBuilder.AddColumn<DateOnly>(
                name: "screen_goal_restore_on",
                table: "children",
                type: "date",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "tip_dismissals",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    user_id = table.Column<Guid>(type: "uuid", nullable: false),
                    key = table.Column<string>(type: "character varying(160)", maxLength: 160, nullable: false),
                    until = table.Column<DateOnly>(type: "date", nullable: true),
                    updated_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_tip_dismissals", x => x.id);
                    table.ForeignKey(
                        name: "fk_tip_dismissals_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_tip_dismissals_users_user_id",
                        column: x => x.user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "ix_tip_dismissals_family_id",
                table: "tip_dismissals",
                column: "family_id");

            migrationBuilder.CreateIndex(
                name: "ix_tip_dismissals_user_id_family_id_key",
                table: "tip_dismissals",
                columns: new[] { "user_id", "family_id", "key" },
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "tip_dismissals");

            migrationBuilder.DropColumn(
                name: "tips_enabled",
                table: "family_members");

            migrationBuilder.DropColumn(
                name: "weekly_report_day",
                table: "family_members");

            migrationBuilder.DropColumn(
                name: "weekly_report_sent_on",
                table: "family_members");

            migrationBuilder.DropColumn(
                name: "weekly_report_time",
                table: "family_members");

            migrationBuilder.DropColumn(
                name: "screen_goal_restore_minutes",
                table: "children");

            migrationBuilder.DropColumn(
                name: "screen_goal_restore_on",
                table: "children");
        }
    }
}
