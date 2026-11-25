using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class Allowance : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "allowance_plans",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    rate_cherries = table.Column<int>(type: "integer", nullable: false),
                    rate_amount = table.Column<decimal>(type: "numeric(10,2)", precision: 10, scale: 2, nullable: false),
                    currency = table.Column<string>(type: "character varying(3)", maxLength: 3, nullable: false),
                    weekly_cherries = table.Column<int>(type: "integer", nullable: false),
                    weekly_paid_for = table.Column<DateOnly>(type: "date", nullable: true),
                    add_to_expenses = table.Column<bool>(type: "boolean", nullable: false),
                    goal_title = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: true),
                    goal_emoji = table.Column<string>(type: "character varying(8)", maxLength: 8, nullable: true),
                    goal_cherries = table.Column<int>(type: "integer", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_allowance_plans", x => x.id);
                    table.ForeignKey(
                        name: "fk_allowance_plans_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_allowance_plans_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "allowance_requests",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    cherries = table.Column<int>(type: "integer", nullable: false),
                    amount = table.Column<decimal>(type: "numeric(12,2)", precision: 12, scale: 2, nullable: false),
                    currency = table.Column<string>(type: "character varying(3)", maxLength: 3, nullable: false),
                    status = table.Column<string>(type: "character varying(10)", maxLength: 10, nullable: false),
                    decided_by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    decided_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    expense_id = table.Column<Guid>(type: "uuid", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_allowance_requests", x => x.id);
                    table.ForeignKey(
                        name: "fk_allowance_requests_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_allowance_requests_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_allowance_requests_users_decided_by_user_id",
                        column: x => x.decided_by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateIndex(
                name: "ix_allowance_plans_child_id",
                table: "allowance_plans",
                column: "child_id",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_allowance_plans_family_id",
                table: "allowance_plans",
                column: "family_id");

            migrationBuilder.CreateIndex(
                name: "ix_allowance_requests_child_id_status",
                table: "allowance_requests",
                columns: new[] { "child_id", "status" });

            migrationBuilder.CreateIndex(
                name: "ix_allowance_requests_decided_by_user_id",
                table: "allowance_requests",
                column: "decided_by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_allowance_requests_family_id_status",
                table: "allowance_requests",
                columns: new[] { "family_id", "status" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "allowance_plans");

            migrationBuilder.DropTable(
                name: "allowance_requests");
        }
    }
}
