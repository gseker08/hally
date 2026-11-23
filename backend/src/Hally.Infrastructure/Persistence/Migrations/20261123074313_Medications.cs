using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class Medications : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "medications",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    created_by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    name = table.Column<string>(type: "character varying(60)", maxLength: 60, nullable: false),
                    dose = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: true),
                    min_interval_minutes = table.Column<int>(type: "integer", nullable: false),
                    max_doses_per_day = table.Column<int>(type: "integer", nullable: true),
                    remind_next_dose = table.Column<bool>(type: "boolean", nullable: false),
                    notes = table.Column<string>(type: "character varying(300)", maxLength: 300, nullable: true),
                    active = table.Column<bool>(type: "boolean", nullable: false),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_medications", x => x.id);
                    table.ForeignKey(
                        name: "fk_medications_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_medications_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_medications_users_created_by_user_id",
                        column: x => x.created_by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateTable(
                name: "medication_doses",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    medication_id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    given_by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    given_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    note = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: true),
                    overrode_warning = table.Column<bool>(type: "boolean", nullable: false),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_medication_doses", x => x.id);
                    table.ForeignKey(
                        name: "fk_medication_doses_medications_medication_id",
                        column: x => x.medication_id,
                        principalTable: "medications",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_medication_doses_users_given_by_user_id",
                        column: x => x.given_by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateIndex(
                name: "ix_medication_doses_family_id_given_at",
                table: "medication_doses",
                columns: new[] { "family_id", "given_at" });

            migrationBuilder.CreateIndex(
                name: "ix_medication_doses_given_by_user_id",
                table: "medication_doses",
                column: "given_by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_medication_doses_medication_id_given_at",
                table: "medication_doses",
                columns: new[] { "medication_id", "given_at" });

            migrationBuilder.CreateIndex(
                name: "ix_medications_child_id",
                table: "medications",
                column: "child_id");

            migrationBuilder.CreateIndex(
                name: "ix_medications_created_by_user_id",
                table: "medications",
                column: "created_by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_medications_family_id_active",
                table: "medications",
                columns: new[] { "family_id", "active" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "medication_doses");

            migrationBuilder.DropTable(
                name: "medications");
        }
    }
}
