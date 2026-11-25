using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class OfflineActivities : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<double>(
                name: "weather_latitude",
                table: "families",
                type: "double precision",
                nullable: true);

            migrationBuilder.AddColumn<double>(
                name: "weather_longitude",
                table: "families",
                type: "double precision",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "weather_place",
                table: "families",
                type: "character varying(80)",
                maxLength: 80,
                nullable: true);

            migrationBuilder.CreateTable(
                name: "family_activities",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    title = table.Column<string>(type: "character varying(60)", maxLength: 60, nullable: false),
                    emoji = table.Column<string>(type: "character varying(8)", maxLength: 8, nullable: false),
                    cherries = table.Column<int>(type: "integer", nullable: false),
                    place = table.Column<string>(type: "character varying(10)", maxLength: 10, nullable: false),
                    by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_family_activities", x => x.id);
                    table.ForeignKey(
                        name: "fk_family_activities_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_family_activities_users_by_user_id",
                        column: x => x.by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateIndex(
                name: "ix_family_activities_by_user_id",
                table: "family_activities",
                column: "by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_family_activities_family_id",
                table: "family_activities",
                column: "family_id");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "family_activities");

            migrationBuilder.DropColumn(
                name: "weather_latitude",
                table: "families");

            migrationBuilder.DropColumn(
                name: "weather_longitude",
                table: "families");

            migrationBuilder.DropColumn(
                name: "weather_place",
                table: "families");
        }
    }
}
